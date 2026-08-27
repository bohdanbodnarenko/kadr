import AnnotationModel
import CoreGraphics
import Foundation
import ImageIO

/// Draws beautify chrome into an export context (docs/03 §3 P2).
///
/// Kept off `AnnotationExportRenderer` so that type stays under the body-length budget;
/// export still goes through one `render` entry point.
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

        let content = document.contentRect
        let radius = min(
            spec.cornerRadius,
            min(layout.contentRect.width, layout.contentRect.height) / 2
        )
        let rounded = CGPath(
            roundedRect: layout.contentRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        if spec.shadow.isEnabled {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: spec.shadow.offsetY),
                blur: spec.shadow.blur,
                color: CGColor(gray: 0, alpha: spec.shadow.opacity)
            )
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(rounded)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(rounded)
        context.clip()
        context.translateBy(
            x: layout.contentRect.minX - content.minX,
            y: layout.contentRect.minY - content.minY
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

    private static func fillBackdrop(_ backdrop: BeautifyBackdrop, in rect: CGRect, context: CGContext) {
        switch backdrop {
        case let .solid(colour):
            context.setFillColor(colour.cgColor)
            context.fill(rect)

        case let .gradient(start, end, angleDegrees):
            fillGradient(start: start, end: end, angleDegrees: angleDegrees, in: rect, context: context)

        case let .image(path):
            if let image = loadBackdropImage(path: path) {
                fillImage(image, in: rect, context: context)
            } else {
                context.setFillColor(CGColor(gray: 0.16, alpha: 1))
                context.fill(rect)
            }
        }
    }

    private static func fillGradient(
        start: AnnotationColor,
        end: AnnotationColor,
        angleDegrees: CGFloat,
        in rect: CGRect,
        context: CGContext
    ) {
        let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: colourSpace,
            colors: [start.cgColor, end.cgColor] as CFArray,
            locations: [0, 1]
        ) else {
            context.setFillColor(start.cgColor)
            context.fill(rect)
            return
        }
        let angle = angleDegrees * .pi / 180
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

    private static func loadBackdropImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
