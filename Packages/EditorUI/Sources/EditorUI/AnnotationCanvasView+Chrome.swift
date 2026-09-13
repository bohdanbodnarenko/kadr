import AnnotationModel
import AnnotationRender
import AppKit
import ImageIO
import QuartzCore
import Shared

/// Where the canvas puts the beautify chrome (docs/03 §3 P2, docs/09 U1.1).
///
/// Split from the canvas's own file because the layer tree and the chrome change for
/// different reasons — and because everything in here draws from `BeautifyLayout`, which
/// the export renderer also draws from, so the two stay honest by sharing a source rather
/// than by being read together.
extension AnnotationCanvasView {
    /// Shows the expensive chrome — the camera's projection and any progressive blur —
    /// or takes it away again (docs/09 U1.2, U1.3).
    ///
    /// Rendered through the same code the export uses rather than approximated with a
    /// `CATransform3D`: the two would have to agree about the sign of every rotation under
    /// a flipped geometry, and a preview that leans the other way from the file is worse
    /// than one that costs a CoreImage pass.
    ///
    /// What makes that affordable is the settle pattern. While a slider is moving, the
    /// last good render stays on screen, stretched — wrong in detail, right in shape, and
    /// free. The real render happens once the value stops moving, which is the only moment
    /// anyone looks closely (docs/09 U1.3).
    /// Re-rasterises the vector chrome for the magnification it is being viewed at.
    ///
    /// Every annotation layer was built with `contentsScale` set to the window's backing
    /// factor and nothing ever changed it, so at 4× zoom a stroke drawn for 2× was blown up
    /// four times — soft edges on exactly the zoom somebody reached for to check an edge.
    /// Setting `contentsScale` on a `CAShapeLayer` re-renders the path at the new density,
    /// which is far cheaper than rebuilding the layer and is the whole fix.
    ///
    /// Clamped at four times the backing scale. Past that the memory a layer costs grows
    /// faster than the detail anybody can see, and the base image is a bitmap that has no
    /// more detail to give in any case.
    func updateContentsScale(forMagnification magnification: CGFloat) {
        let backing = window?.backingScaleFactor ?? 2
        let scale = min(max(backing * magnification, backing), backing * 4)
        guard abs(scale - lastContentsScale) > 0.01 else { return }
        lastContentsScale = scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for parent in [annotationLayer, reviewLayer, draftLayer, selectionLayer, cropLayer] {
            parent.contentsScale = scale
            applyContentsScale(scale, to: parent.sublayers)
        }
    }

    /// Depth-first, because a composed annotation is a layer with layers inside it.
    private func applyContentsScale(_ scale: CGFloat, to layers: [CALayer]?) {
        guard let layers else { return }
        for layer in layers {
            // A layer showing a bitmap gains nothing and would only re-interpolate it; the
            // vector ones are the ones that resolve.
            if layer.contents == nil {
                layer.contentsScale = scale
            }
            applyContentsScale(scale, to: layer.sublayers)
        }
    }

    func updateExpensiveChrome() {
        guard needsOffscreenRender else {
            chromeSettle.cancel()
            cameraLayer.isHidden = true
            cameraLayer.contents = nil
            contentHost.isHidden = false
            setDrawingLayersHidden(false)
            backdropLayer.opacity = 1
            return
        }

        // Something changed, so the render on screen is now stale. Showing it anyway is
        // the cheap preview: it is the previous frame of a drag, which is a better guess
        // than anything that could be computed inside 16 ms.
        chromeSettle.touch()
        if cameraLayer.contents == nil {
            // Nothing to stretch yet — the first frame has to be real, or the canvas is
            // blank until the user stops moving.
            renderExpensiveChrome()
        } else {
            showOffscreenLayer()
        }
    }

    /// Whether the chrome needs a full offscreen render rather than the plain layer tree.
    private var needsOffscreenRender: Bool {
        model.document.cameraGeometry != nil || model.document.progressiveBlur != nil
    }

    /// The real thing: the whole canvas, rendered through the export path.
    ///
    /// Off the main actor (docs/10 R1.5). This is the full export renderer over the whole
    /// canvas — a 100–300 ms CoreImage pass on a 5K capture — and it used to run inline on
    /// every slider release, which is a stall exactly where somebody is judging the result.
    ///
    /// The stretched preview already on screen is the right thing to show meanwhile: it is
    /// the previous render at the wrong scale, which is a far better guess than a blank
    /// canvas and is what the settle pattern puts there anyway.
    func renderExpensiveChrome() {
        guard needsOffscreenRender else { return }

        // A newer render wins. Two settles can overlap — release one slider and touch the
        // next before the first finishes — and the older result arriving second would put
        // a stale picture on screen and leave it there.
        chromeRenderGeneration &+= 1
        let generation = chromeRenderGeneration
        let document = model.document
        let image = baseImage

        Task.detached(priority: .userInitiated) {
            let rendered = try? AnnotationExportRenderer().render(
                baseImage: image,
                document: document,
                applyOrientation: false
            )
            await MainActor.run { [weak self] in
                guard let self, generation == chromeRenderGeneration else { return }
                applyRenderedChrome(rendered)
            }
        }
    }

    private func applyRenderedChrome(_ rendered: CGImage?) {
        guard let rendered else {
            // A render we cannot do leaves the flat canvas visible, which is wrong but
            // legible — the alternative is a blank editor.
            cameraLayer.isHidden = true
            contentHost.isHidden = false
            setDrawingLayersHidden(false)
            backdropLayer.opacity = 1
            return
        }
        cameraLayer.contents = rendered
        showOffscreenLayer()
    }

    /// Puts the offscreen render on screen and hides everything it already contains.
    private func showOffscreenLayer() {
        contentHost.isHidden = true
        setDrawingLayersHidden(true)
        shadowLayer.isHidden = true
        backdropLayer.opacity = 0
        cameraLayer.isHidden = false
        cameraLayer.frame = CGRect(origin: .zero, size: model.document.canvasRect.size)
        cameraLayer.contentsGravity = .resize
    }

    /// Annotation chrome lives on the canvas, not inside the card — hide it when the
    /// flattened offscreen render is covering that same drawing.
    private func setDrawingLayersHidden(_ hidden: Bool) {
        annotationLayer.isHidden = hidden
        reviewLayer.isHidden = hidden
        draftLayer.isHidden = hidden
        selectionLayer.isHidden = hidden
        cropLayer.isHidden = hidden || model.tool != .crop
    }

    func layoutCanvasChrome() {
        lastLayoutKey = canvasLayoutKey()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let imageBounds = model.document.baseImage.bounds
        let showsFullCapture = model.tool == .crop
        guard !showsFullCapture, let spec = model.document.beautify, let layout = model.document.beautifyLayout else {
            layoutPlainCanvas(imageBounds: imageBounds, showsFullCapture: showsFullCapture)
            applyCanvasOrientation()
            return
        }
        layoutBeautifiedCanvas(spec: spec, layout: layout, imageBounds: imageBounds)
        applyCanvasOrientation()
    }

    /// Crop mode and the un-beautified editor: the capture, optionally clipped to the crop.
    private func layoutPlainCanvas(imageBounds: CGRect, showsFullCapture: Bool) {
        setFrameSize(showsFullCapture ? imageBounds.size : model.document.canvasRect.size)
        layer?.masksToBounds = !showsFullCapture
        backdropLayer.isHidden = true
        shadowLayer.isHidden = true
        contentHost.mask = nil
        contentHost.frame = bounds
        contentHost.cornerRadius = 0
        contentHost.masksToBounds = !showsFullCapture
        contentHost.borderWidth = 1
        contentHost.borderColor = NSColor.separatorColor.cgColor
        let drawing = showsFullCapture
            ? CGRect(origin: .zero, size: imageBounds.size)
            : model.document.imageSpaceFrame
        baseLayer.frame = drawing
        applyDrawingFrames(drawing)
        updateExpensiveChrome()
    }

    private func layoutBeautifiedCanvas(spec: BeautifySpec, layout: BeautifyLayout, imageBounds: CGRect) {
        let content = model.document.contentRect
        setFrameSize(layout.canvasSize)
        layer?.masksToBounds = false
        backdropLayer.isHidden = false
        backdropLayer.frame = bounds
        applyBackdrop(spec.backdrop)

        let cardPath = RoundedCornerPath.path(
            in: CGRect(origin: .zero, size: layout.cardRect.size),
            corners: layout.corners
        )
        applyShadow(spec.shadow, layout: layout, cardPath: cardPath)

        contentHost.frame = layout.cardRect
        contentHost.cornerRadius = 0
        contentHost.masksToBounds = true
        contentHost.borderWidth = 0
        contentHost.borderColor = nil
        let cardMask = contentHost.mask as? CAShapeLayer ?? CAShapeLayer()
        cardMask.frame = CGRect(origin: .zero, size: layout.cardRect.size)
        cardMask.path = cardPath
        contentHost.mask = cardMask

        baseLayer.frame = CGRect(
            x: -content.minX,
            y: -content.minY,
            width: imageBounds.width,
            height: imageBounds.height
        )
        applyDrawingFrames(model.document.imageSpaceFrame)
        updateExpensiveChrome()
    }

    private func applyDrawingFrames(_ drawing: CGRect) {
        annotationLayer.frame = drawing
        draftLayer.frame = drawing
        selectionLayer.frame = drawing
        reviewLayer.frame = drawing
        cropLayer.frame = drawing
    }

    /// Draws the card's shadow without laying anything opaque behind the capture.
    ///
    /// A shadow layer filled with the card's own shape backs a transparent screenshot with
    /// solid colour. The fill is therefore knocked out with an even-odd mask, leaving only
    /// the blur that falls outside the card — the same trick the export renderer uses, for
    /// the same reason (docs/08 §2.1).
    func applyShadow(_ shadow: BeautifyShadow, layout: BeautifyLayout, cardPath: CGPath) {
        shadowLayer.isHidden = !shadow.isEnabled
        guard shadow.isEnabled else { return }

        let shortestEdge = min(layout.cardRect.width, layout.cardRect.height)
        let blur = shadow.blur.resolved(shortestEdge: shortestEdge)
        let offsetY = shadow.offsetY.resolved(shortestEdge: shortestEdge)

        shadowLayer.frame = layout.cardRect
        shadowLayer.backgroundColor = nil
        shadowLayer.cornerRadius = 0
        let fill = shadowLayer.sublayers?.first as? CAShapeLayer ?? {
            let layer = CAShapeLayer()
            shadowLayer.addSublayer(layer)
            return layer
        }()
        fill.frame = shadowLayer.bounds
        fill.path = cardPath
        fill.fillColor = NSColor.black.cgColor
        fill.shadowOpacity = Float(shadow.opacity)
        // CALayer's shadowRadius is a standard deviation where CGContext's blur is a
        // diameter, which is the factor of two.
        fill.shadowRadius = blur / 2
        fill.shadowOffset = CGSize(width: 0, height: offsetY)
        fill.shadowColor = NSColor.black.cgColor
        fill.shadowPath = cardPath

        let knockout = fill.mask as? CAShapeLayer ?? CAShapeLayer()
        knockout.frame = fill.bounds
        let outside = CGMutablePath()
        let reach = blur * 2 + abs(offsetY) + 1
        outside.addRect(fill.bounds.insetBy(dx: -reach, dy: -reach))
        outside.addPath(cardPath)
        knockout.path = outside
        knockout.fillRule = .evenOdd
        knockout.fillColor = NSColor.black.cgColor
        fill.mask = knockout
    }

    func applyBackdrop(_ backdrop: BeautifyBackdrop) {
        gradientLayer.isHidden = true
        backdropLayer.contents = nil
        switch backdrop {
        case let .solid(colour):
            backdropLayer.backgroundColor = NSColor(
                srgbRed: colour.red,
                green: colour.green,
                blue: colour.blue,
                alpha: colour.alpha
            ).cgColor
        case let .gradient(ramp):
            backdropLayer.backgroundColor = nil
            gradientLayer.isHidden = false
            gradientLayer.frame = backdropLayer.bounds
            let stops = ramp.stops
            gradientLayer.colors = stops.map { stop in
                NSColor(
                    srgbRed: stop.color.red,
                    green: stop.color.green,
                    blue: stop.color.blue,
                    alpha: stop.color.alpha
                ).cgColor
            }
            gradientLayer.locations = stops.map { NSNumber(value: Double($0.location)) }
            // Unit space, y downwards to match the flipped view: 90° reads top to bottom,
            // exactly as the export renderer's angle does.
            let angle = ramp.angleDegrees * .pi / 180
            gradientLayer.startPoint = CGPoint(x: 0.5 - cos(angle) / 2, y: 0.5 - sin(angle) / 2)
            gradientLayer.endPoint = CGPoint(x: 0.5 + cos(angle) / 2, y: 0.5 + sin(angle) / 2)
        case let .image(path):
            backdropLayer.backgroundColor = NSColor.darkGray.cgColor
            // Through the cache, at a bucketed size: dragging a slider re-lays the canvas
            // on every tick, and decoding a 6K wallpaper each time is what makes the panel
            // feel broken (docs/09 U1.1).
            backdropLayer.contents = WallpaperCache.shared.image(
                at: path,
                longestEdge: max(backdropLayer.bounds.width, backdropLayer.bounds.height)
                    * (window?.backingScaleFactor ?? 2)
            )
            backdropLayer.contentsGravity = .resizeAspectFill
        }
    }
}

/// Geometry that forces a chrome re-lay. Style-only edits leave all of this alone.
/// Crop-mode pins the capture to its full size so dragging the overlay does not
/// re-lay the canvas on every mouse-move (that was the jump).
struct CanvasLayoutKey: Equatable {
    var canvas: CGSize
    var content: CGRect
    var imageSpace: CGRect
    var beautify: BeautifySpec?
    var isCropping: Bool
    var orientation: CanvasOrientation
}

extension AnnotationCanvasView {
    func canvasLayoutKey() -> CanvasLayoutKey {
        if model.tool == .crop {
            let bounds = model.document.baseImage.bounds
            return CanvasLayoutKey(
                canvas: bounds.size,
                content: bounds,
                imageSpace: CGRect(origin: .zero, size: bounds.size),
                beautify: nil,
                isCropping: true,
                orientation: model.document.orientation
            )
        }
        return CanvasLayoutKey(
            canvas: model.document.canvasRect.size,
            content: model.document.contentRect,
            imageSpace: model.document.imageSpaceFrame,
            beautify: model.document.beautify,
            isCropping: false,
            orientation: model.document.orientation
        )
    }
}
