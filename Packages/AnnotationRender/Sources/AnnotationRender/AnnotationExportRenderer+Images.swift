import AnnotationModel
import CoreGraphics
import Foundation

extension AnnotationExportRenderer {
    /// An inserted image, with its shadow and rounded corners (docs/06 M24).
    func drawImage(_ spec: ImageSpec, in context: CGContext) {
        guard let image = ImageRendering.decode(spec.pngData) else { return }
        let rect = spec.rect.standardized
        guard !rect.isEmpty else { return }

        context.saveGState()
        context.setAlpha(spec.opacity)
        if spec.hasShadow, objectShadowsEnabled {
            let radius = ImageRendering.shadowRadius(spec)
            context.setShadow(
                offset: CGSize(width: 0, height: -radius / 2),
                blur: radius,
                color: CGColor(gray: 0, alpha: 0.35)
            )
        }
        if spec.cornerRadius > 0 {
            // Clipping needs its own state: the shadow is cast by the drawing, and a clip
            // applied to the shadow as well would square its corners off again.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.addPath(ImageRendering.clipPath(spec))
            context.clip()
        }

        // Images are drawn in the flipped space every command works in, so the transform
        // is undone around this one draw rather than the image being mirrored.
        context.translateBy(x: 0, y: rect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)

        if spec.cornerRadius > 0 {
            context.endTransparencyLayer()
        }
        context.restoreGState()
    }

    func drawCounter(_ spec: CounterSpec, in context: CGContext) {
        CounterRendering.draw(spec, in: context)
    }
}
