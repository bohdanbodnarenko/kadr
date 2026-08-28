import AnnotationModel
import CoreGraphics
import Foundation
import ImageIO

/// Draws beautify chrome into an export context (docs/03 §3 P2, docs/09 U1.1).
///
/// Kept off `AnnotationExportRenderer` so that type stays under the body-length budget;
/// export still goes through one `render` entry point. Layout is not computed here — it
/// comes from `BeautifyLayout`, so the live canvas and the export cannot disagree.
/// Everything a card render needs about *what* to draw, as against *where*.
///
/// Bundled because it travels together through four functions unchanged, and four
/// parameter lists repeating the same four things is four chances to reorder them.
struct CardContents {
    var source: CGImage
    var document: AnnotationDocument
    var includeAnnotations: Bool
    var drawCommand: (AnnotationCommand, CGContext) -> Void
}

enum BeautifyCompositor {
    static func compose(
        source: CGImage,
        document: AnnotationDocument,
        includeAnnotations: Bool,
        in context: CGContext,
        drawCommand: @escaping (AnnotationCommand, CGContext) -> Void
    ) {
        let contents = CardContents(
            source: source,
            document: document,
            includeAnnotations: includeAnnotations,
            drawCommand: drawCommand
        )
        guard let spec = document.beautify, let layout = document.beautifyLayout else { return }
        let canvasBounds = CGRect(origin: .zero, size: layout.canvasSize)
        fillBackdrop(spec.backdrop, in: canvasBounds, context: context)

        // With a camera, the card is projected — so the shape casting the shadow is the
        // projected quad, not the upright rectangle (docs/09 U1.2).
        let camera = document.cameraGeometry
        let cardPath = RoundedCornerPath.path(in: layout.cardRect, corners: layout.corners)
        let shadowPath = camera.map { CameraCompositor.path(of: $0.quad) } ?? cardPath
        if spec.shadow.isEnabled {
            drawShadow(spec.shadow, around: shadowPath, in: layout, canvas: canvasBounds, context: context)
        }

        // A projected card, or one with its own blur, has to be flattened offscreen first;
        // otherwise the card is drawn straight into the canvas.
        let blur = document.progressiveBlur.flatMap { $0.extent == .clipped ? $0 : nil }
        if camera != nil || blur != nil {
            let drawn = drawFlattenedCard(contents, layout: layout, camera: camera, blur: blur, in: context)
            if drawn {
                return
            }
        }

        drawBorder(spec.border, layout: layout, cardPath: cardPath, in: context)
        context.saveGState()
        context.addPath(imagePath(layout))
        context.clip()
        drawCard(contents, imageOrigin: layout.imageRect.origin, in: context)
        context.restoreGState()
    }

    /// The ring around the capture (docs/09 U1.4).
    ///
    /// Drawn as a filled card behind the capture rather than as a stroked outline: a stroke
    /// straddles its path, so half of it would fall inside the image and cover the
    /// screenshot's own edge. Filling the card and drawing the capture inset on top gives a
    /// ring whose thickness is exactly what was asked for, and whose inner curve is
    /// concentric with its outer one.
    static func drawBorder(
        _ border: BeautifyBorder,
        layout: BeautifyLayout,
        cardPath: CGPath,
        in context: CGContext
    ) {
        guard border.isEnabled else { return }
        context.saveGState()
        context.setFillColor(border.color.cgColor)
        context.addPath(cardPath)
        context.fillPath()
        context.restoreGState()
    }

    /// The rounded shape the capture is clipped to: the card's inner edge.
    static func imagePath(_ layout: BeautifyLayout) -> CGPath {
        RoundedCornerPath.path(in: layout.imageRect, corners: layout.imageCorners)
    }

    /// Draws the capture and everything on it, positioned so `document.contentRect` lands
    /// at `imageOrigin`. The caller has already clipped to whatever shape it wants.
    static func drawCard(_ contents: CardContents, imageOrigin: CGPoint, in context: CGContext) {
        let document = contents.document
        let content = document.contentRect
        context.saveGState()
        context.translateBy(x: imageOrigin.x - content.minX, y: imageOrigin.y - content.minY)
        if document.crop?.canExpandCanvas == true {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(content)
        }
        context.draw(contents.source, in: document.baseImage.bounds)
        if contents.includeAnnotations {
            for command in document.commands {
                contents.drawCommand(command, context)
            }
        }
        context.restoreGState()
    }

    /// Renders the card flat, blurs and projects it, and draws the result.
    ///
    /// Returns false if the offscreen render failed, so the caller can fall back to drawing
    /// the card upright and sharp — a plain screenshot beats an empty canvas.
    ///
    /// The order is blur *then* project, because a depth-of-field blur belongs to the
    /// picture rather than to the lens looking at it: blurring after the projection would
    /// smear the tilted edges instead of softening the content.
    private static func drawFlattenedCard(
        _ contents: CardContents,
        layout: BeautifyLayout,
        camera: AnnotationCameraGeometry?,
        blur: ProgressiveBlurSpec?,
        in context: CGContext
    ) -> Bool {
        let scale = contents.document.baseImage.scale
        guard var card = renderCard(contents, layout: layout, scale: scale) else { return false }

        if let blur {
            let localCard = CGRect(origin: .zero, size: layout.cardRect.size)
            card = ProgressiveBlurCompositor.apply(blur, to: card, in: localCard, scale: scale) ?? card
        }

        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        let destination: CGRect
        let drawable: CGImage
        if let camera {
            guard let projected = CameraCompositor.project(
                card: card,
                onto: camera.quad,
                canvasSize: layout.canvasSize,
                scale: scale
            ) else {
                return false
            }
            drawable = projected
            destination = canvas
        } else {
            drawable = card
            destination = layout.cardRect
        }

        // Drawn in the flipped space every command works in, so the transform is undone
        // around this one draw rather than the bitmap being mirrored.
        context.saveGState()
        context.translateBy(x: 0, y: destination.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(drawable, in: destination)
        context.restoreGState()
        return true
    }

    /// The card, flat, with its rounded corners already applied — the bitmap the camera
    /// projects.
    private static func renderCard(
        _ contents: CardContents,
        layout: BeautifyLayout,
        scale: CGFloat
    ) -> CGImage? {
        let pixelWidth = Int((layout.cardRect.width * scale).rounded())
        let pixelHeight = Int((layout.cardRect.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let cardContext = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: contents.source.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        cardContext.scaleBy(x: scale, y: scale)
        cardContext.translateBy(x: 0, y: layout.cardRect.height)
        cardContext.scaleBy(x: 1, y: -1)

        // The card's own space: its origin is the bitmap's origin, so the shapes are built
        // at zero and the capture is placed relative to that.
        let localCard = CGRect(origin: .zero, size: layout.cardRect.size)
        let imageOrigin = CGPoint(
            x: layout.imageRect.minX - layout.cardRect.minX,
            y: layout.imageRect.minY - layout.cardRect.minY
        )
        let localLayout = BeautifyLayout(
            canvasSize: layout.cardRect.size,
            cardRect: localCard,
            imageRect: CGRect(origin: imageOrigin, size: layout.imageRect.size),
            corners: layout.corners,
            imageCorners: layout.imageCorners
        )
        let localPath = RoundedCornerPath.path(in: localCard, corners: layout.corners)

        cardContext.addPath(localPath)
        cardContext.clip()
        drawBorder(
            contents.document.beautify?.border ?? .none,
            layout: localLayout,
            cardPath: localPath,
            in: cardContext
        )
        cardContext.saveGState()
        cardContext.addPath(imagePath(localLayout))
        cardContext.clip()
        drawCard(contents, imageOrigin: imageOrigin, in: cardContext)
        cardContext.restoreGState()
        return cardContext.makeImage()
    }

    /// Draws the card's shadow without putting anything opaque behind the card.
    ///
    /// The obvious implementation — set a shadow, fill the card path — paints an opaque
    /// rectangle under the capture. That is invisible for a screenshot of a solid window
    /// and ruinous for one with transparency: a capture of a rounded window or a
    /// transparent terminal comes out backed by flat black rather than the backdrop
    /// (docs/08 §2.1).
    ///
    /// The fix is to clip the card out first and only then fill it. An even-odd path of
    /// the canvas plus the card clips to everything *outside* the card, so the fill itself
    /// lands entirely in clipped-away territory and only the blur spilling past the edge
    /// survives. Nothing opaque is ever drawn where the capture goes.
    static func drawShadow(
        _ shadow: BeautifyShadow,
        around card: CGPath,
        in layout: BeautifyLayout,
        canvas: CGRect,
        context: CGContext
    ) {
        let shortestEdge = min(layout.cardRect.width, layout.cardRect.height)
        let blur = shadow.blur.resolved(shortestEdge: shortestEdge)
        let offsetY = shadow.offsetY.resolved(shortestEdge: shortestEdge)

        context.saveGState()
        // Clip to the canvas so a shadow at a stuck edge is cut off there rather than
        // smeared into a caller's larger context.
        context.clip(to: canvas)

        // Then clip the card away. Reach far enough outside the canvas that the outer
        // rectangle's own edge is never a boundary anything is drawn against.
        let reach = blur * 2 + abs(offsetY) + 1
        let outside = CGMutablePath()
        outside.addRect(canvas.insetBy(dx: -reach, dy: -reach))
        outside.addPath(card)
        context.addPath(outside)
        context.clip(using: .evenOdd)

        context.setShadow(
            offset: CGSize(width: 0, height: offsetY),
            blur: blur,
            color: CGColor(gray: 0, alpha: shadow.opacity)
        )
        // The fill is entirely inside the clipped-away card, so only its shadow lands.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(card)
        context.fillPath()
        context.restoreGState()
    }

    private static func fillBackdrop(_ backdrop: BeautifyBackdrop, in rect: CGRect, context: CGContext) {
        switch backdrop {
        case let .solid(colour):
            context.setFillColor(colour.cgColor)
            context.fill(rect)

        case let .gradient(ramp):
            fillGradient(ramp, in: rect, context: context)

        case let .image(path):
            let longestEdge = max(rect.width, rect.height)
            if let image = WallpaperCache.shared.image(at: path, longestEdge: longestEdge) {
                fillImage(image, in: rect, context: context)
            } else {
                context.setFillColor(CGColor(gray: 0.16, alpha: 1))
                context.fill(rect)
            }
        }
    }

    private static func fillGradient(_ ramp: BeautifyGradient, in rect: CGRect, context: CGContext) {
        let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let stops = ramp.stops
        guard let gradient = CGGradient(
            colorsSpace: colourSpace,
            colors: stops.map(\.color.cgColor) as CFArray,
            locations: stops.map(\.location)
        ) else {
            context.setFillColor(ramp.start.cgColor)
            context.fill(rect)
            return
        }
        let angle = ramp.angleDegrees * .pi / 180
        let length = hypot(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let startPoint = CGPoint(x: center.x - cos(angle) * length, y: center.y - sin(angle) * length)
        let endPoint = CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient,
            start: startPoint,
            end: endPoint,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    /// Fills `rect` with `image`, scaled to cover and centred — the wallpaper behaviour
    /// every desktop uses, so nothing is letterboxed and nothing is distorted.
    private static func fillImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        context.saveGState()
        context.clip(to: rect)
        context.draw(image, in: CGRect(origin: origin, size: drawSize))
        context.restoreGState()
    }
}
