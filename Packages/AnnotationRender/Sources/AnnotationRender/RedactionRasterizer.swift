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

    /// Pads the region so the Gaussian samples real neighbours, then cuts back to the box
    /// (Screendrop's `makeBlurredImage`). Crop-then-clamp only repeats the box's own edge
    /// and looks like a sharp, "pure" rectangle of slightly softened pixels.
    private func previewBlur(_ image: CGImage, rect: CGRect, radius: CGFloat, scale: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let pixels = pixelRect(rect, scale: scale, in: ci.extent)
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        let blurred = gaussianBlur(ci, in: pixels, radius: radius * scale)
        return KadrRenderContext.shared.createCGImage(blurred, from: pixels)
    }

    /// Core Image space: pixels, origin at the bottom-left of the bitmap.
    private func pixelRect(_ rect: CGRect, scale: CGFloat, in extent: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: extent.height - rect.maxY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(extent)
    }

    /// A Gaussian that samples past the box, then is clipped to it — Screendrop's
    /// `CIFilter.gaussianBlur` path, with the same radius mapping.
    private func gaussianBlur(_ image: CIImage, in rect: CGRect, radius: CGFloat) -> CIImage {
        let sigma = max(radius, 1)
        let pad = ceil(sigma * 2)
        let padded = rect.insetBy(dx: -pad, dy: -pad).intersection(image.extent)
        return image
            .cropped(to: padded)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
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
