import AnnotationModel
import CoreGraphics
import CoreImage
import Foundation
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

        let context = CIContext(options: [.useSoftwareRenderer: false])
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
                blurred(output, in: pixels, radius: radius * scale)
            case let .pixelate(cellSize):
                pixelated(output, in: pixels, cellSize: cellSize * scale, generator: &generator)
            }
            output = obscured.cropped(to: pixels).composited(over: output)
        }

        guard let result = context.createCGImage(output, from: extent) else {
            logger.error("Could not rasterise redactions; returning the image unchanged")
            return image
        }
        return result
    }

    /// A Gaussian blur that samples from a clamped image, so edges do not darken.
    private func blurred(_ image: CIImage, in rect: CGRect, radius: CGFloat) -> CIImage {
        image
            .cropped(to: rect)
            // Without clamping, the blur pulls in transparent pixels from beyond the edge
            // and the region fades out at its borders.
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(max(radius, 1)))
    }

    /// A mosaic whose cells sample from jittered positions.
    private func pixelated(
        _ image: CIImage,
        in rect: CGRect,
        cellSize: CGFloat,
        generator: inout SeededGenerator
    ) -> CIImage {
        let size = max(cellSize, 2)
        // Offsetting the mosaic's centre by up to a cell moves which pixel each cell
        // averages, so the grid does not line up predictably with the content.
        let jitterX = CGFloat.random(in: -size ... size, using: &generator)
        let jitterY = CGFloat.random(in: -size ... size, using: &generator)

        return image
            .cropped(to: rect)
            .clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: rect.midX + jitterX, y: rect.midY + jitterY),
                kCIInputScaleKey: size
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
