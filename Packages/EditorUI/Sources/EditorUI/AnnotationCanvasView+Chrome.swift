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
    /// Shows the camera's projection, or takes it away again (docs/09 U1.2).
    ///
    /// Rendered through the same code the export uses rather than approximated with a
    /// `CATransform3D`: the two would have to agree about the sign of every rotation under
    /// a flipped geometry, and a preview that leans the other way from the file is worse
    /// than a preview that costs a CoreImage pass. U1.3's settle-preview is where the
    /// cheap live approximation belongs.
    func updateCameraPreview() {
        guard model.document.cameraGeometry != nil else {
            cameraLayer.isHidden = true
            cameraLayer.contents = nil
            contentHost.isHidden = false
            backdropLayer.opacity = 1
            return
        }

        let canvas = model.document.canvasRect
        guard let projected = try? AnnotationExportRenderer().render(
            baseImage: baseImage,
            document: model.document
        ) else {
            // A projection we cannot render leaves the flat canvas visible, which is wrong
            // but legible — the alternative is a blank editor.
            cameraLayer.isHidden = true
            contentHost.isHidden = false
            return
        }

        // The projection already contains the backdrop and the card, so everything the
        // flat path draws is hidden rather than drawn underneath it.
        contentHost.isHidden = true
        shadowLayer.isHidden = true
        backdropLayer.opacity = 0
        cameraLayer.isHidden = false
        cameraLayer.frame = CGRect(origin: .zero, size: canvas.size)
        cameraLayer.contents = projected
        cameraLayer.contentsGravity = .resize
    }

    func layoutCanvasChrome() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let imageBounds = model.document.baseImage.bounds
        let content = model.document.contentRect

        guard let spec = model.document.beautify, let layout = model.document.beautifyLayout else {
            setFrameSize(imageBounds.size)
            backdropLayer.isHidden = true
            shadowLayer.isHidden = true
            contentHost.frame = bounds
            contentHost.cornerRadius = 0
            contentHost.masksToBounds = false
            let drawing = CGRect(origin: .zero, size: imageBounds.size)
            baseLayer.frame = drawing
            annotationLayer.frame = drawing
            draftLayer.frame = drawing
            selectionLayer.frame = drawing
            reviewLayer.frame = drawing
            updateCameraPreview()
            return
        }

        setFrameSize(layout.canvasSize)
        backdropLayer.isHidden = false
        backdropLayer.frame = bounds
        applyBackdrop(spec.backdrop)

        // The same path the export renderer builds, so the live canvas and the file agree
        // about where the corners are (docs/09 U1.1).
        let cardPath = RoundedCornerPath.path(
            in: CGRect(origin: .zero, size: layout.cardRect.size),
            corners: layout.corners
        )

        applyShadow(spec.shadow, layout: layout, cardPath: cardPath)

        contentHost.frame = layout.cardRect
        contentHost.cornerRadius = 0
        contentHost.masksToBounds = true
        let cardMask = contentHost.mask as? CAShapeLayer ?? CAShapeLayer()
        cardMask.frame = CGRect(origin: .zero, size: layout.cardRect.size)
        cardMask.path = cardPath
        contentHost.mask = cardMask

        let drawing = CGRect(
            x: -content.minX,
            y: -content.minY,
            width: imageBounds.width,
            height: imageBounds.height
        )
        baseLayer.frame = drawing
        annotationLayer.frame = drawing
        draftLayer.frame = drawing
        selectionLayer.frame = drawing
        reviewLayer.frame = drawing
        updateCameraPreview()
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
