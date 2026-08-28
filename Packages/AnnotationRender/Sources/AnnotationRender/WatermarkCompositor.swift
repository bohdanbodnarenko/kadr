import AnnotationModel
import CoreGraphics
import CoreText
import Foundation

/// Draws a watermark over the finished canvas (docs/09 U1.4).
///
/// Last of everything, deliberately. A watermark that the perspective camera could tilt or
/// the progressive blur could soften would be a watermark someone can remove by turning
/// those off — the mark belongs to the exported file, not to the picture inside it.
enum WatermarkCompositor {
    /// The font every watermark uses.
    ///
    /// One face rather than a choice: a watermark is a mark, not typography, and the
    /// inspector has enough knobs. Bold because a translucent mark in a regular weight
    /// disappears against a busy screenshot.
    static let fontName = "Helvetica-Bold"

    /// Draws `spec` over `rect`, in a context already flipped to the model's top-left
    /// space like every other command.
    static func draw(_ spec: WatermarkSpec, in rect: CGRect, context: CGContext) {
        guard !spec.isIdentity else { return }

        let shortestEdge = max(min(rect.width, rect.height), 1)
        let fontSize = spec.fontSize.resolved(shortestEdge: shortestEdge)
        guard fontSize > 0 else { return }

        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: spec.text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): spec.color.cgColor
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let layout = WatermarkLayout.compute(
            spec,
            in: rect,
            textSize: CGSize(width: bounds.width, height: bounds.height)
        )
        guard !layout.placements.isEmpty else { return }

        context.saveGState()
        context.setAlpha(spec.opacity)
        // Clipped to the canvas: a tiled grid is deliberately larger than the picture so
        // its corners are covered, and the overspill must not reach a caller's context.
        context.clip(to: rect)

        for placement in layout.placements {
            context.saveGState()
            // Text draws in CoreGraphics' own orientation, so the canvas flip is undone
            // around each mark — the same dance every other text command does.
            context.translateBy(x: placement.center.x, y: placement.center.y)
            context.scaleBy(x: 1, y: -1)
            context.rotate(by: -placement.rotationDegrees * .pi / 180)
            context.textPosition = CGPoint(
                x: -bounds.width / 2 - bounds.minX,
                y: -bounds.height / 2 - bounds.minY
            )
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
