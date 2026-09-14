import AnnotationModel
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Shared

/// Applies a blur that varies across the image (docs/09 U1.3).
///
/// Three stacked Gaussians with a ramped mask, not `CIMaskedVariableBlur`. The masked
/// filter is one pass and it bands; stacking the way a live photographic blur does keeps
/// the middle sharp and the edges actually soft. The gradient that decides *where* is
/// still built in `ProgressiveBlurMask`, so the geometry can be tested without rendering.
///
/// Note what this is *not*: the redaction blur. That one burns irreversibly into the pixels
/// over a rectangle the user drew, and carries a security claim (docs/03 §3). This is
/// decoration, and the two share no code on purpose.
enum ProgressiveBlurCompositor {
    /// Blurs `image`, which occupies `rect` in points, at `scale` pixels per point.
    ///
    /// Returns nil when CoreImage declines, so the caller can draw the image unblurred —
    /// a crisp screenshot beats an empty one.
    static func apply(
        _ spec: ProgressiveBlurSpec,
        to image: CGImage,
        in rect: CGRect,
        scale: CGFloat
    ) -> CGImage? {
        guard !spec.isIdentity, rect.width > 0, rect.height > 0 else { return nil }
        let mask = ProgressiveBlurMask.resolve(spec, in: rect)
        guard mask.blurRadius > 0 else { return nil }

        // CoreImage is bottom-left and in pixels; the mask is top-left and in points.
        let pixelRect = CGRect(
            x: 0,
            y: 0,
            width: (rect.width * scale).rounded(),
            height: (rect.height * scale).rounded()
        )
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }

        let source = CIImage(cgImage: image)
        guard let gradient = makeGradient(mask, rect: rect, pixelRect: pixelRect, scale: scale) else {
            return nil
        }

        // Three stacked Gaussians, the same approximation a photographic progressive blur
        // uses live: `CIMaskedVariableBlur` bands, stacked Gaussians look like glass.
        // Stronger levels cover weaker ones as the mask ramps up, so the sharp region
        // stays sharp and the edges go properly soft.
        let clamped = source.clampedToExtent()
        var composite = source.cropped(to: pixelRect)
        let levels = 3
        for level in 0 ..< levels {
            let start = CGFloat(level) / CGFloat(levels)
            let end = CGFloat(level + 1) / CGFloat(levels)
            let radius = max(mask.blurRadius * scale * end, 0.5)
            let blurred = clamped
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: pixelRect)
            let band = bandMask(gradient, start: start, end: end)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = blurred
            blend.backgroundImage = composite
            blend.maskImage = band
            composite = blend.outputImage ?? composite
        }
        return KadrRenderContext.shared.createCGImage(composite, from: pixelRect)
    }

    /// The greyscale ramp: black where the image stays sharp, white where it is fully
    /// blurred.
    private static func makeGradient(
        _ mask: ProgressiveBlurMask,
        rect: CGRect,
        pixelRect: CGRect,
        scale: CGFloat
    ) -> CIImage? {
        let sharp = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        let blurred = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        // Inverting swaps which end of the ramp is sharp, which is all "blur the middle
        // instead of the edges" means.
        let inner = mask.isInverted ? blurred : sharp
        let outer = mask.isInverted ? sharp : blurred

        /// Model points to CoreImage pixels, flipping y within the target rect.
        func toPixels(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (point.x - rect.minX) * scale,
                y: (rect.maxY - point.y) * scale
            )
        }

        let gradient: CIImage?
        if mask.isRadial {
            let filter = CIFilter.radialGradient()
            filter.center = toPixels(mask.center)
            filter.radius0 = Float(mask.innerRadius * scale)
            filter.radius1 = Float(mask.outerRadius * scale)
            filter.color0 = inner
            filter.color1 = outer
            gradient = filter.outputImage
        } else {
            let filter = CIFilter.linearGradient()
            filter.point0 = toPixels(mask.start)
            filter.point1 = toPixels(mask.end)
            filter.color0 = inner
            filter.color1 = outer
            gradient = filter.outputImage
        }

        // Gradients are infinite; the blur needs one the size of the image.
        return gradient?.cropped(to: pixelRect)
    }

    /// Remaps a 0…1 gradient so this stack level ramps from clear to opaque across its
    /// band, then stays opaque — later, stronger blurs cover the weaker ones.
    private static func bandMask(_ gradient: CIImage, start: CGFloat, end: CGFloat) -> CIImage {
        let width = max(end - start, 0.001)
        return gradient
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 / width, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 / width, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 / width, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -start / width, y: -start / width, z: -start / width, w: 0)
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
    }
}
