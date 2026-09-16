import AnnotationModel
import CoreGraphics
import CoreImage
import Foundation
import os
import Shared

/// Burns blur, pixelate and erase regions into the image itself (docs/03 §3, docs/04 §6).
///
/// This is the security-relevant part of the editor. A blur drawn as an overlay on top of
/// a PNG can be removed by anyone who opens the file — the original pixels are still
/// there. So redaction is *rasterised into the base image* before anything else is drawn,
/// and the exported file contains no recoverable original.
///
/// Two rules the whole file follows:
///
/// * **Strength is in the capture's pixels**, the way Screendrop measures it. Multiplying by
///   the backing scale doubled every blur and mosaic on a Retina capture, which is what
///   turned a readable-but-hidden blur into a flat grey slab.
/// * **Preview and export are the same algorithm.** The canvas used to preview pixelate with
///   an averaged mosaic and export a different, single-pixel one, so the saved file looked
///   nothing like what was drawn. Export differs from preview only in its random seed.
public struct RedactionRasterizer: Sendable {
    private let logger = KadrLog.logger(.capture)

    public init() {}

    /// A live crop of the screenshot, redacted the way export will redact it.
    ///
    /// Editing has to look like the real effect — a grey rectangle is not a redaction.
    public func preview(_ spec: RedactionSpec, from image: CGImage, scale: CGFloat) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let box = Self.pixelBox(of: spec.rect, scale: scale).intersection(bounds)
        guard !box.isNull, box.width >= 1, box.height >= 1 else { return nil }

        switch spec.style {
        case let .blur(radius):
            return previewBlur(image, box: box, sigma: max(radius, 1))
        case let .pixelate(cellSize):
            guard let crop = image.cropping(to: box) else { return nil }
            // Seeded from the annotation, so the mosaic holds still while its box is
            // dragged instead of reshuffling on every mouse-move.
            var generator = SeededGenerator(seed: Self.previewSeed(for: spec.id))
            return mosaic(crop, cellSize: Self.cellPixels(cellSize), generator: &generator)
        case .erase:
            guard let crop = image.cropping(to: box) else { return nil }
            let sample = Self.dominantEdgeColor(of: crop)
            return solidImage(width: Int(box.width), height: Int(box.height), sample: sample)
        }
    }

    /// A box in points as the integral pixel rect the preview crops, top-left origin.
    static func pixelBox(of rect: CGRect, scale: CGFloat) -> CGRect {
        let rect = rect.standardized
        return CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
    }

    /// Blurs the box's own pixels, its edges extended outward, the way Screendrop does.
    ///
    /// The crop happens on the `CGImage`, before CoreImage sees anything: `CIImage(cgImage:)`
    /// of the full capture pushes the entire bitmap to the GPU on every call, and this one
    /// runs on every mouse-move while a redaction box is dragged. `CGImage.cropping` shares
    /// the original's backing store, so the crop itself costs nothing.
    private func previewBlur(_ image: CGImage, box: CGRect, sigma: CGFloat) -> CGImage? {
        guard let crop = image.cropping(to: box) else { return nil }
        let input = CIImage(cgImage: crop)
        return KadrRenderContext.shared.createCGImage(ownPixelsBlur(input, sigma: sigma), from: input.extent)
    }

    /// The box's pixels blurred with its own edges repeated outward, then clipped to it.
    ///
    /// Not padded with the surrounding image. Sampling neighbours past the box bled whatever
    /// sat just outside — a bright line of text above, a dark bar below — into a band along
    /// each edge, which read as a smear stuck to a sharp picture. Clamping keeps the box one
    /// even blur to its edge, and means nothing outside the box ever enters the redaction.
    private func ownPixelsBlur(_ region: CIImage, sigma: CGFloat) -> CIImage {
        blur(region.clampedToExtent(), sigma: sigma).cropped(to: region.extent)
    }

    private func gaussianBlur(_ image: CIImage, in rect: CGRect, sigma: CGFloat) -> CIImage {
        ownPixelsBlur(image.cropped(to: rect), sigma: sigma)
    }

    /// The blur itself, on an image already cropped and clamped to what it needs.
    ///
    /// A plain `CIGaussianBlur`, deliberately: it is flat in sigma here (CoreImage already
    /// shrinks internally for wide radii), and shrinking by hand first measured slower.
    private func blur(_ source: CIImage, sigma: CGFloat) -> CIImage {
        source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
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
                gaussianBlur(output, in: pixels, sigma: max(radius, 1))
            case let .pixelate(cellSize):
                pixelated(output, in: pixels, cellSize: cellSize, context: context, generator: &generator)
            case .erase:
                erased(output, in: pixels, context: context)
            }
            output = obscured.cropped(to: pixels).composited(over: output)
        }

        guard let result = context.createCGImage(output, from: extent) else {
            logger.error("Could not rasterise redactions; returning the image unchanged")
            return image
        }
        return result
    }

    // MARK: - Pixelate

    /// The region, rendered, mosaicked on the CPU and handed back — see `PixelateMosaic`.
    ///
    /// `CIPixellate` cannot express the jittered windows: it averages a fixed grid, and its
    /// only knob is where that grid's centre sits (docs/07 M3).
    private func pixelated(
        _ image: CIImage,
        in rect: CGRect,
        cellSize: CGFloat,
        context: CIContext,
        generator: inout SeededGenerator
    ) -> CIImage {
        guard let region = context.createCGImage(image, from: rect),
              let mosaicked = mosaic(region, cellSize: Self.cellPixels(cellSize), generator: &generator)
        else {
            logger.error("Could not build a jittered mosaic; falling back to an even one")
            return evenMosaic(image, in: rect, cellSize: max(cellSize, 2))
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
            space: Self.workingSpace,
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

    static func cellPixels(_ cellSize: CGFloat) -> Int {
        max(Int(cellSize.rounded()), 2)
    }

    /// A stable seed per annotation, for the preview only.
    ///
    /// Stability is all it needs: export draws a fresh, unrecorded seed, so nothing about the
    /// saved file can be reproduced from the document.
    static func previewSeed(for id: AnnotationID) -> UInt64 {
        withUnsafeBytes(of: id.rawValue.uuid) { $0.loadUnaligned(as: UInt64.self) }
    }

    // MARK: - Erase

    private func erased(_ image: CIImage, in rect: CGRect, context: CIContext) -> CIImage {
        let sample = if let region = context.createCGImage(image, from: rect) {
            Self.dominantEdgeColor(of: region)
        } else {
            EdgeSample.fallback
        }
        let color = CIColor(red: sample.red, green: sample.green, blue: sample.blue)
        return CIImage(color: color).cropped(to: rect)
    }

    /// The colour the region's border mostly is.
    ///
    /// A histogram of the one-pixel ring, not a mean. The old eight-sample mean landed
    /// between text and its background — a grey box erasing a line of a dark terminal — and
    /// read the bytes as RGBA whatever the capture's layout was. The border of a box drawn
    /// over UI is mostly background, so the commonest colour there is the background.
    static func dominantEdgeColor(of image: CGImage) -> EdgeSample {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return .fallback }

        // Only the one-pixel ring is read, so only the ring is drawn: four strips rather than
        // the whole region. Drawing a 2000×1000 box to look at its border was a 8 MB
        // allocation and a full decode on the main actor, per mouse-move (docs/10 R1).
        guard let top = Self.strip(of: image, CGRect(x: 0, y: 0, width: width, height: 1)),
              let bottom = Self.strip(of: image, CGRect(x: 0, y: height - 1, width: width, height: 1)),
              let left = Self.strip(of: image, CGRect(x: 0, y: 0, width: 1, height: height)),
              let right = Self.strip(of: image, CGRect(x: width - 1, y: 0, width: 1, height: height))
        else { return .fallback }

        var histogram = EdgeHistogram()
        let perimeter = 2 * (width + height)
        let step = max(1, perimeter / 4000)
        for x in stride(from: 0, to: width, by: step) {
            histogram.add(top, offset: x * 4)
            histogram.add(bottom, offset: x * 4)
        }
        for y in stride(from: 0, to: height, by: step) {
            histogram.add(left, offset: y * 4)
            histogram.add(right, offset: y * 4)
        }
        return histogram.dominant ?? .fallback
    }

    /// One edge of `image` as RGBA8 bytes, row-major from the top.
    private static func strip(of image: CGImage, _ rect: CGRect) -> [UInt8]? {
        guard let cropped = image.cropping(to: rect) else { return nil }
        let width = cropped.width
        let height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: workingSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    private func solidImage(width: Int, height: Int, sample: EdgeSample) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: Self.workingSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(
            colorSpace: Self.workingSpace,
            components: [sample.red, sample.green, sample.blue, 1]
        ) ?? CGColor(gray: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// sRGB throughout, so preview, export and the erase fill agree on what a colour is.
    static let workingSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

/// A colour sampled from a region's edge, 0 to 1 per channel.
struct EdgeSample: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    static let fallback = EdgeSample(red: 0.85, green: 0.85, blue: 0.85)
}

/// Counts edge pixels by colour, 16 levels a channel, and keeps each bucket's true mean.
private struct EdgeHistogram {
    private struct Sum {
        var red = 0
        var green = 0
        var blue = 0
    }

    private var counts: [Int: Int] = [:]
    private var sums: [Int: Sum] = [:]

    mutating func add(_ pixels: [UInt8], offset: Int) {
        guard offset >= 0, offset + 3 < pixels.count, pixels[offset + 3] > 0 else { return }
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let key = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)
        counts[key, default: 0] += 1
        sums[key, default: Sum()].red += red
        sums[key, default: Sum()].green += green
        sums[key, default: Sum()].blue += blue
    }

    var dominant: EdgeSample? {
        guard let (key, count) = counts.max(by: { $0.value < $1.value }), let sum = sums[key] else {
            return nil
        }
        let scale = CGFloat(count * 255)
        return EdgeSample(
            red: CGFloat(sum.red) / scale,
            green: CGFloat(sum.green) / scale,
            blue: CGFloat(sum.blue) / scale
        )
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
