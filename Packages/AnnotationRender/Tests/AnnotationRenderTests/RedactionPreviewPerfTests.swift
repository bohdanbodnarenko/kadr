import AnnotationModel
import CoreGraphics
import CoreImage
import Foundation
import Shared
import Testing
@testable import AnnotationRender

/// What the blur preview is allowed to touch (docs/03 §3).
///
/// This path runs on every mouse-move while a redaction box is dragged
/// (`AnnotationCanvasView.updateDraftLayer`), so its cost is a frame budget rather than a
/// one-off. It used to wrap the whole capture in a `CIImage` and crop inside CoreImage,
/// which pushed the entire 4K bitmap through the context on first use: measured at 12.15 ms
/// against 1.05 ms for cropping the `CGImage` first, and the same 1.0 ms once warm.
///
/// The guard is the output rather than a stopwatch. Wall-clock here is worthless: these
/// tests run in parallel and contend for the GPU, which is how an earlier version of this
/// file reported the same 27 ms for a 300×200 box and a 1600×900 one.
///
/// The blur reads the box and nothing else — its own edges are extended outward rather than
/// the surrounding capture padded in, which is what keeps a redaction's edges clean.
@Suite("Redaction preview region")
struct RedactionPreviewRegionTests {
    /// The preview is exactly the box, wherever the box is — including flush with an edge,
    /// where a padded region used to be clipped on one side only.
    @Test("The preview is the size of its box, anywhere in the capture", arguments: [
        CGRect(x: 900, y: 500, width: 600, height: 400),
        CGRect(x: 0, y: 0, width: 300, height: 200),
        CGRect(x: 1300, y: 800, width: 300, height: 200)
    ])
    func previewIsTheBox(rect: CGRect) throws {
        let image = RedactionPreviewSamplingTests.striped(width: 1600, height: 1000)
        for radius in [CGFloat(1), 12, 60] {
            let spec = RedactionSpec(rect: rect, style: .blur(radius: radius))
            let preview = try #require(RedactionRasterizer().preview(spec, from: image, scale: 1))
            #expect(preview.width == Int(rect.width), "radius \(radius) grew the preview")
            #expect(preview.height == Int(rect.height), "radius \(radius) grew the preview")
        }
    }
}

/// The preview has to blur the part of the capture the box is actually over (docs/03 §3).
///
/// Cropping the `CGImage` before CoreImage sees it moved a coordinate flip: the box is in
/// the image's top-left space, the crop is a window onto it, and `CIImage(cgImage:)` puts
/// row zero at the top — so the y flips within the crop rather than within the whole image
/// (CLAUDE.md rule 6). Getting that wrong samples somewhere else entirely and still returns
/// a plausible-looking blurred rectangle, so it needs a test that knows where the colours
/// are.
@Suite("Redaction preview sampling")
struct RedactionPreviewSamplingTests {
    /// Black across the top half, white across the bottom.
    static func halved(width: Int, height: Int) -> CGImage {
        guard let context = RedactionPreviewSamplingTests.bitmapContext(width: width, height: height) else {
            fatalError("Could not build the test pattern")
        }
        // CGContext draws with the origin at the bottom left, so this fills the *bottom*.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        guard let image = context.makeImage() else {
            fatalError("Could not build the test pattern")
        }
        return image
    }

    /// Mean luminance of a CGImage, 0 to 1.
    static func meanLuminance(_ image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let total = stride(from: 0, to: pixels.count, by: 4).reduce(0.0) { sum, index in
            sum + Double(pixels[index])
        }
        return total / Double(width * height) / 255
    }

    /// The reference: wrap the whole capture, cut the box out inside CoreImage — whose y runs
    /// bottom-up — and blur its own pixels with the edges extended.
    ///
    /// The fast path crops the `CGImage` instead, top-down, so the two only agree if the flip
    /// between those spaces is right.
    static func wholeImagePreview(_ image: CGImage, rect: CGRect, radius: CGFloat, scale: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let extent = ci.extent
        let pixels = CGRect(
            x: rect.minX * scale,
            y: extent.height - rect.maxY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(extent)
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        let sigma = max(radius, 1)
        let out = ci.cropped(to: pixels).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
        return KadrRenderContext.shared.createCGImage(out, from: pixels)
    }

    /// Cropping first must produce the same picture, including for a box against an edge.
    ///
    /// The edge cases are the point: a box whose position differs between the top-down and
    /// bottom-up spaces only when the flip is written wrong has to be off-centre vertically.
    ///
    /// The radius matters as much as the box. Comparing two heavily blurred images hides
    /// exactly the error being looked for: at sigma 12 the blur washes out any detail fine
    /// enough to reveal a 24-point shift, so the shifted result and the correct one differ by
    /// almost nothing. The edge cases use a small radius over a coarse pattern, so what the
    /// box is over still survives the blur.
    @Test(
        "Cropping first gives the same picture as blurring the whole image",
        arguments: [
            (CGRect(x: 400, y: 300, width: 400, height: 200), CGFloat(12)),
            (CGRect(x: 0, y: 0, width: 400, height: 200), CGFloat(3)),
            (CGRect(x: 1200, y: 800, width: 400, height: 200), CGFloat(3)),
            (CGRect(x: 0, y: 400, width: 300, height: 300), CGFloat(3))
        ]
    )
    func croppingFirstMatchesTheReference(rect: CGRect, radius: CGFloat) throws {
        let image = Self.striped(width: 1600, height: 1000)
        let spec = RedactionSpec(rect: rect, style: .blur(radius: radius))

        let fast = try #require(RedactionRasterizer().preview(spec, from: image, scale: 1))
        let reference = try #require(Self.wholeImagePreview(image, rect: rect, radius: radius, scale: 1))

        #expect(fast.width == reference.width)
        #expect(fast.height == reference.height)
        let difference = Self.meanAbsoluteDifference(fast, reference)
        #expect(difference < 0.02, "the fast path differs from the reference by \(difference)")
    }

    /// A coarse checkerboard: big enough that a small blur does not erase it, so a region
    /// sampled a few points off comes back visibly different.
    static func striped(width: Int, height: Int) -> CGImage {
        guard let context = bitmapContext(width: width, height: height) else {
            fatalError("Could not build the test pattern")
        }
        let cell = 40
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for row in 0 ... (height / cell) {
            for column in 0 ... (width / cell) where (row + column).isMultiple(of: 2) {
                context.fill(CGRect(x: column * cell, y: row * cell, width: cell, height: cell))
            }
        }
        guard let image = context.makeImage() else {
            fatalError("Could not build the test pattern")
        }
        return image
    }

    /// A bitmap context in the one format `CGContext` reliably accepts.
    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Mean per-pixel difference of two images of the same size, 0 to 1.
    static func meanAbsoluteDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        let left = bytes(of: lhs)
        let right = bytes(of: rhs)
        guard left.count == right.count, !left.isEmpty else { return 1 }
        let total = zip(left, right).reduce(0.0) { sum, pair in
            sum + abs(Double(pair.0) - Double(pair.1))
        }
        return total / Double(left.count) / 255
    }

    static func bytes(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// The image is black on top and white underneath, in the coordinates a redaction rect
    /// uses. A box in the top half must come back dark, and one in the bottom light — the
    /// two mirror each other, so a flipped y makes each fail with the other's answer.
    @Test(
        "A box samples the half of the capture it is over",
        arguments: [
            (CGRect(x: 100, y: 40, width: 400, height: 200), false),
            (CGRect(x: 100, y: 760, width: 400, height: 200), true)
        ]
    )
    func boxSamplesItsOwnHalf(rect: CGRect, expectsLight: Bool) throws {
        let image = Self.halved(width: 1600, height: 1000)
        let spec = RedactionSpec(rect: rect, style: .blur(radius: 12))
        let preview = try #require(RedactionRasterizer().preview(spec, from: image, scale: 1))

        let luminance = Self.meanLuminance(preview)
        if expectsLight {
            #expect(luminance > 0.75, "a box over the light half came back at \(luminance)")
        } else {
            #expect(luminance < 0.25, "a box over the dark half came back at \(luminance)")
        }
    }
}
