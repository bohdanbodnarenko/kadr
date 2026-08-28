import AnnotationModel
import CoreGraphics
import Foundation
import ImageIO

/// Draws beautify chrome into an export context (docs/03 §3 P2, docs/09 U1.1).
///
/// Kept off `AnnotationExportRenderer` so that type stays under the body-length budget;
/// export still goes through one `render` entry point. Layout is not computed here — it
/// comes from `BeautifyLayout`, so the live canvas and the export cannot disagree.
enum BeautifyCompositor {
    static func compose(
        source: CGImage,
        document: AnnotationDocument,
        includeAnnotations: Bool,
        in context: CGContext,
        drawCommand: (AnnotationCommand, CGContext) -> Void
    ) {
        guard let spec = document.beautify, let layout = document.beautifyLayout else { return }
        let canvasBounds = CGRect(origin: .zero, size: layout.canvasSize)
        fillBackdrop(spec.backdrop, in: canvasBounds, context: context)

        let card = RoundedCornerPath.path(in: layout.cardRect, corners: layout.corners)
        if spec.shadow.isEnabled {
            drawShadow(spec.shadow, around: card, in: layout, canvas: canvasBounds, context: context)
        }

        let content = document.contentRect
        context.saveGState()
        context.addPath(card)
        context.clip()
        context.translateBy(
            x: layout.imageRect.minX - content.minX,
            y: layout.imageRect.minY - content.minY
        )
        if document.crop?.canExpandCanvas == true {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(content)
        }
        context.draw(source, in: document.baseImage.bounds)
        if includeAnnotations {
            for command in document.commands {
                drawCommand(command, context)
            }
        }
        context.restoreGState()
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
    private static func drawShadow(
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
