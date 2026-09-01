import AnnotationModel
import CoreGraphics
import CoreImage
import Foundation
import os
import Shared

/// Burns blur and pixelate regions into the image itself (docs/03 §3, docs/04 §6).
///
/// This is the security-relevant part of the editor. A blur drawn as an overlay on top of
/// a PNG can be removed by anyone who opens the file — the original pixels are still
/// there. So redaction is *rasterised into the base image* before anything else is drawn,
/// and the exported file contains no recoverable original.
///
/// Pixelation adds randomised per-cell displacement for a related reason: an even mosaic
/// over known glyph shapes is attackable, because the average colour of each cell leaks
/// the character underneath. Jittering which pixel each cell samples breaks that.
public struct RedactionRasterizer: Sendable {
    private let logger = KadrLog.logger(.capture)

    public init() {}

    /// A live crop of the screenshot, blurred or pixelated the way the canvas shows it.
    ///
    /// Editing has to look like the real effect — a grey rectangle is not a redaction.
    /// Export still goes through `apply`, which burns the same region into the full image
    /// with the security jitter on pixelate. This path is the preview: sample the
    /// pixels under the box (Screendrop's `AnnoShapeDrawing.drawRedaction`).
    public func preview(_ spec: RedactionSpec, from image: CGImage, scale: CGFloat) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        switch spec.style {
        case let .blur(radius):
            return previewBlur(image, rect: spec.rect, radius: max(radius, 1), scale: scale)
        case let .pixelate(cellSize):
            let crop = CGRect(
                x: spec.rect.minX * scale,
                y: spec.rect.minY * scale,
                width: spec.rect.width * scale,
                height: spec.rect.height * scale
            ).integral.intersection(bounds)
            guard crop.width >= 1, crop.height >= 1 else { return nil }
            return previewPixelate(image, crop: crop, cellSize: max(cellSize * scale, 2))
        }
    }

    /// Pads the region so the Gaussian samples real neighbours, then cuts back to the box.
    ///
    /// The crop happens on the `CGImage`, before CoreImage sees anything. That is the whole
    /// performance story on this path: `CIImage(cgImage:)` of the full capture, rendered
    /// through a context that deliberately keeps no intermediates, pushes the entire
    /// 4K bitmap to the GPU on every call — and this one runs on every mouse-move while a
    /// redaction box is being dragged. Cropping first bounds the work to the region the user
    /// is actually blurring. `CGImage.cropping` shares the original's backing store, so the
    /// crop itself costs nothing.
    private func previewBlur(_ image: CGImage, rect: CGRect, radius: CGFloat, scale: CGFloat) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sigma = max(radius * scale, 1)
        let box = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(bounds)
        guard box.width >= 1, box.height >= 1 else { return nil }

        let padded = Self.paddedCropRect(box: box, sigma: sigma, bounds: bounds)
        guard padded.width >= 1, padded.height >= 1, let crop = image.cropping(to: padded) else { return nil }

        let blurred = blur(CIImage(cgImage: crop).clampedToExtent(), sigma: sigma)
        // `box` is in the image's top-left space and `crop` is a window onto it;
        // `CIImage(cgImage:)` puts row zero at the top, so the y has to be flipped within
        // the crop rather than within the whole image (CLAUDE.md rule 6).
        let output = CGRect(
            x: box.minX - padded.minX,
            y: padded.maxY - box.maxY,
            width: box.width,
            height: box.height
        )
        return KadrRenderContext.shared.createCGImage(blurred, from: output)
    }

    /// The region handed to CoreImage: the box, plus enough margin for the Gaussian to have
    /// real neighbours to sample.
    ///
    /// Two sigmas of padding is where a Gaussian's contribution has fallen away to nothing.
    /// Without it the blur has only the box's own edge to mix in, and a redaction comes out
    /// looking like a flat rectangle of slightly softened pixels rather than something the
    /// image continues into.
    ///
    /// Exposed because it is the shape of the work: everything outside this rect is data the
    /// preview must never touch, and a redaction box is usually a small part of a large
    /// capture.
    static func paddedCropRect(box: CGRect, sigma: CGFloat, bounds: CGRect) -> CGRect {
        let pad = ceil(max(sigma, 1) * 2)
        return box.insetBy(dx: -pad, dy: -pad).integral.intersection(bounds)
    }

    /// A Gaussian that samples past the box, then is clipped to it.
    ///
    /// The padding is what keeps a redaction from looking like a flat rectangle of slightly
    /// softened pixels: crop-then-clamp only repeats the box's own edge, so the blur has no
    /// neighbours to mix in.
    private func gaussianBlur(_ image: CIImage, in rect: CGRect, radius: CGFloat) -> CIImage {
        let sigma = max(radius, 1)
        let pad = ceil(sigma * 2)
        let padded = rect.insetBy(dx: -pad, dy: -pad).intersection(image.extent)
        return blur(image.cropped(to: padded).clampedToExtent(), sigma: sigma)
    }

    /// The blur itself, on an image already cropped and clamped to what it needs.
    ///
    /// A plain `CIGaussianBlur`, deliberately. The obvious optimisation is to shrink the
    /// region, blur with a proportionally smaller sigma and scale back — a Gaussian is
    /// scale-covariant, so it should cost far less for the same picture. Measured on a 4K
    /// capture it is the wrong trade: `CIGaussianBlur` is flat in sigma here (0.77 ms at
    /// sigma 8, 0.88 at sigma 60 — CoreImage already shrinks internally for wide radii),
    /// and adding a Lanczos pass to shrink it myself took it to 1.38 ms. Slower, and a
    /// resampling artifact to worry about, for nothing.
    private func blur(_ source: CIImage, sigma: CGFloat) -> CIImage {
        source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
    }

    /// Fast mosaic for the canvas: downsample then nearest-neighbour up, the way Screendrop
    /// previews pixelate. Export uses the jittered mosaic (`PixelateMosaic`) instead.
    private func previewPixelate(_ image: CGImage, crop: CGRect, cellSize: CGFloat) -> CGImage? {
        guard let sampled = image.cropping(to: crop) else { return nil }
        let block = max(1, Int(cellSize.rounded()))
        let smallWidth = max(1, sampled.width / block)
        let smallHeight = max(1, sampled.height / block)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let down = CGContext(
            data: nil,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        down.interpolationQuality = .medium
        down.draw(sampled, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let small = down.makeImage() else { return nil }

        guard let up = CGContext(
            data: nil,
            width: sampled.width,
            height: sampled.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        up.interpolationQuality = .none
        up.draw(small, in: CGRect(x: 0, y: 0, width: sampled.width, height: sampled.height))
        return up.makeImage()
    }

    /// Applies every redaction in a document to a copy of the base image.
    ///
    /// - Parameters:
    ///   - image: the base image, in pixels.
    ///   - scale: pixels per point, since redaction rects are in points.
    ///   - randomSeed: fixes the pixelate jitter, so tests are deterministic. Production
    ///     passes `nil` and gets real randomness.
    public func apply(
        _ redactions: [RedactionSpec],
        to image: CGImage,
        scale: CGFloat,
        randomSeed: UInt64? = nil
    ) -> CGImage {
        guard !redactions.isEmpty else { return image }

        let context = KadrRenderContext.shared
        var output = CIImage(cgImage: image)
        let extent = output.extent
        var generator = SeededGenerator(seed: randomSeed ?? UInt64.random(in: .min ... .max))

        for redaction in redactions {
            // Redaction rects are in points with a top-left origin; CoreImage works in
            // pixels with a bottom-left origin.
            let pixels = CGRect(
                x: redaction.rect.minX * scale,
                y: extent.height - redaction.rect.maxY * scale,
                width: redaction.rect.width * scale,
                height: redaction.rect.height * scale
            ).integral.intersection(extent)
            guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { continue }

            let obscured = switch redaction.style {
            case let .blur(radius):
                gaussianBlur(output, in: pixels, radius: max(radius * scale, 1))
            case let .pixelate(cellSize):
                pixelated(
                    output,
                    in: pixels,
                    cellSize: cellSize * scale,
                    context: context,
                    generator: &generator
                )
            }
            output = obscured.cropped(to: pixels).composited(over: output)
        }

        guard let result = context.createCGImage(output, from: extent) else {
            logger.error("Could not rasterise redactions; returning the image unchanged")
            return image
        }
        return result
    }

    /// A mosaic whose every cell samples from its own displaced point.
    ///
    /// `CIPixellate` cannot express this: it averages a fixed grid, and its only knob is
    /// where that grid's centre sits. So the region is rendered, mosaicked on the CPU, and
    /// handed back — see `PixelateMosaic` for why per-cell matters (docs/07 M3).
    private func pixelated(
        _ image: CIImage,
        in rect: CGRect,
        cellSize: CGFloat,
        context: CIContext,
        generator: inout SeededGenerator
    ) -> CIImage {
        let size = max(cellSize, 2)
        guard let region = context.createCGImage(image, from: rect),
              let mosaicked = mosaic(region, cellSize: Int(size.rounded()), generator: &generator)
        else {
            logger.error("Could not build a jittered mosaic; falling back to an even one")
            return evenMosaic(image, in: rect, cellSize: size)
        }
        // Back into the source image's own coordinates: `CIImage(cgImage:)` starts at the
        // origin, and this region does not.
        return CIImage(cgImage: mosaicked)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Renders `image` into a buffer, mosaics it, and returns the result.
    private func mosaic(_ image: CGImage, cellSize: Int, generator: inout SeededGenerator) -> CGImage? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        guard width > 0, height > 0 else { return nil }

        // Explicitly allocated: a `CGContext` writes through the pointer it is given for as
        // long as it lives, which is longer than an inout access to a Swift array.
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        bytes.initialize(repeating: 0, count: bytesPerRow * height)
        defer { bytes.deallocate() }

        guard let context = CGContext(
            data: bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        PixelateMosaic.apply(
            to: MutableBitmap(pixels: bytes, width: width, height: height, bytesPerRow: bytesPerRow),
            cellSize: cellSize,
            generator: &generator
        )
        return context.makeImage()
    }

    /// The fallback when the region cannot be rendered: an even mosaic is still a redaction,
    /// and losing the jitter is better than losing the redaction.
    private func evenMosaic(_ image: CIImage, in rect: CGRect, cellSize: CGFloat) -> CIImage {
        image
            .cropped(to: rect)
            .clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY),
                kCIInputScaleKey: cellSize
            ])
    }
}

/// A reproducible random source, so pixelate jitter can be pinned in tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Zero is a fixed point of the mixer, so it must not be the state.
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64: small, fast and good enough for jitter.
        state &+= 0x9E37_79B9_7F4A_7C15
        var result = state
        result = (result ^ (result >> 30)) &* 0xBF58_476D_1CE4_E5B9
        result = (result ^ (result >> 27)) &* 0x94D0_49BB_1331_11EB
        return result ^ (result >> 31)
    }
}
