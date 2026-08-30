import AnnotationModel
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import os
import Shared

/// Applies a blur that varies across the image (docs/09 U1.3).
///
/// `CIMaskedVariableBlur` takes a greyscale mask and blurs each pixel by the mask's value
/// there — white is the full radius, black is untouched. So the whole effect is: build the
/// right gradient, hand it over. Everything interesting is in the gradient, which is why
/// the gradient is decided in `ProgressiveBlurMask` where it can be tested without
/// rendering anything.
///
/// Note what this is *not*: the redaction blur. That one burns irreversibly into the pixels
/// over a rectangle the user drew, and carries a security claim (docs/03 §3). This is
/// decoration, and the two share no code on purpose.
enum ProgressiveBlurCompositor {
    private static let logger = KadrLog.logger(.capture)

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

        let filter = CIFilter.maskedVariableBlur()
        // Clamped, or the blur pulls in transparent pixels from beyond the edge and the
        // whole image fades out at its borders — the same reason the redaction blur clamps.
        filter.inputImage = source.clampedToExtent()
        filter.mask = gradient
        filter.radius = Float(mask.blurRadius * scale)

        guard let output = filter.outputImage else {
            logger.error("The progressive blur produced no image; drawing it sharp")
            return nil
        }
        return KadrRenderContext.shared.createCGImage(output, from: pixelRect)
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
}
