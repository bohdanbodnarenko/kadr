import AnnotationModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AnnotationRender

/// The chrome drawn around a beautified capture (docs/03 §3 P2, docs/09 U1.1).
///
/// These read pixels rather than trusting the layout, because the failures worth catching
/// here are all "the number was right and the drawing was wrong": a shadow painted under a
/// transparent capture, a corner that squares in the layout and rounds in the file.
@Suite("Beautify chrome")
struct BeautifyChromeTests {
    private let renderer = AnnotationExportRenderer()

    /// A capture that is *transparent in the middle* — the case the even-odd knockout
    /// exists for, and the one a naive shadow ruins.
    private func makeTransparentImage(size: Int = 200) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = { () -> CGImage? in
            // Left as cleared pixels: fully transparent, alpha zero.
            context.makeImage()
        }() else {
            fatalError("Could not create a transparent test capture")
        }
        return image
    }

    private func makeOpaqueImage(size: Int = 200, red: CGFloat = 1) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not create a test capture")
        }
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else {
            fatalError("Could not create a test capture")
        }
        return image
    }

    /// One sampled pixel.
    private struct Sample {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    /// One pixel's RGBA, sampled from the exported image.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> Sample {
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        bytes.initialize(repeating: 0, count: 4)
        defer { bytes.deallocate() }
        guard let context = CGContext(
            data: bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not create a sampling context")
        }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Sample(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }

    private func document(_ spec: BeautifySpec, size: CGFloat = 200) -> AnnotationDocument {
        AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: size, height: size), scale: 1),
            commands: [.beautify(spec)]
        )
    }

    // MARK: - The shadow knockout

    /// The docs/08 §2.1 failure, stated directly: fill the card path to cast its shadow and
    /// a transparent screenshot comes back backed by flat black.
    @Test("A transparent capture is backed by the backdrop, not by the shadow's fill")
    func transparentCaptureIsNotBackedByBlack() throws {
        let green = AnnotationColor(red: 0, green: 1, blue: 0)
        let spec = BeautifySpec(
            padding: .points(40),
            cornerRadius: .zero,
            backdrop: .solid(green),
            shadow: BeautifyShadow(opacity: 0.6, blur: .points(20), offsetY: .points(8)),
            aspect: .original,
            alignment: .center,
            sticksToEdges: false
        )
        let image = try renderer.render(baseImage: makeTransparentImage(), document: document(spec))

        // Dead centre of the card, where the capture is fully transparent.
        let middle = pixel(image, x: image.width / 2, y: image.height / 2)
        #expect(middle.green > 200, "the backdrop should show through, got \(middle)")
        #expect(middle.red < 60)
        #expect(middle.blue < 60)
    }

    @Test("The shadow is still drawn outside the card")
    func shadowExistsOutsideTheCard() throws {
        let white = AnnotationColor(red: 1, green: 1, blue: 1)
        let spec = BeautifySpec(
            padding: .points(40),
            cornerRadius: .zero,
            backdrop: .solid(white),
            shadow: BeautifyShadow(opacity: 0.9, blur: .points(16), offsetY: .points(6)),
            aspect: .original,
            alignment: .center,
            sticksToEdges: false
        )
        let image = try renderer.render(baseImage: makeOpaqueImage(), document: document(spec))

        // Compared as bands rather than single pixels: which way a blur falls off is a
        // Core Graphics detail, but "darker beside the card than in the corner" is the
        // behaviour, and it holds whichever edge the offset pushes it towards.
        let beside = (image.width / 2 - 3 ... image.width / 2 + 3).map { x in
            Int(pixel(image, x: x, y: image.height / 2 + 102).red)
        }
        let corner = (2 ... 8).map { x in Int(pixel(image, x: x, y: 2).red) }
        let besideAverage = beside.reduce(0, +) / beside.count
        let cornerAverage = corner.reduce(0, +) / corner.count

        #expect(cornerAverage > 250, "the far corner should be clean backdrop, got \(cornerAverage)")
        #expect(besideAverage < cornerAverage, "the card should cast a shadow, got \(besideAverage)")
    }

    @Test("With the shadow off, the backdrop is untouched")
    func noShadowNoDarkening() throws {
        let white = AnnotationColor(red: 1, green: 1, blue: 1)
        let spec = BeautifySpec(
            padding: .points(40),
            cornerRadius: .zero,
            backdrop: .solid(white),
            shadow: .none,
            aspect: .original,
            alignment: .center,
            sticksToEdges: false
        )
        let image = try renderer.render(baseImage: makeOpaqueImage(), document: document(spec))

        let below = pixel(image, x: image.width / 2, y: image.height / 2 + 105)
        #expect(below.red > 250)
        #expect(below.green > 250)
    }

    // MARK: - Stuck edges, in pixels

    @Test("A capture stuck to the bottom really reaches the bottom of the file")
    func stuckBottomReachesTheEdge() throws {
        let blue = AnnotationColor(red: 0, green: 0, blue: 1)
        let spec = BeautifySpec(
            padding: .points(40),
            cornerRadius: .points(30),
            backdrop: .solid(blue),
            shadow: .none,
            aspect: .square,
            alignment: .bottom,
            sticksToEdges: true
        )
        let image = try renderer.render(baseImage: makeOpaqueImage(), document: document(spec))

        let bottomMiddle = pixel(image, x: image.width / 2, y: image.height - 1)
        #expect(bottomMiddle.red > 200, "the capture should run right off the bottom, got \(bottomMiddle)")

        let topMiddle = pixel(image, x: image.width / 2, y: 1)
        #expect(topMiddle.blue > 200, "and the backdrop should still be above it")
    }

    /// The corner behaviour, in the file rather than in the layout value: a stuck bottom
    /// corner is square, so the capture's colour reaches it.
    @Test("A stuck corner is square in the exported pixels")
    func stuckCornerIsSquare() throws {
        let blue = AnnotationColor(red: 0, green: 0, blue: 1)
        let spec = BeautifySpec(
            padding: .points(40),
            cornerRadius: .points(40),
            backdrop: .solid(blue),
            shadow: .none,
            aspect: .original,
            alignment: .bottomTrailing,
            sticksToEdges: true
        )
        let image = try renderer.render(baseImage: makeOpaqueImage(), document: document(spec))

        let stuckCorner = pixel(image, x: image.width - 2, y: image.height - 2)
        #expect(stuckCorner.red > 200, "the stuck corner should be square, got \(stuckCorner)")

        // The far corner keeps its radius, so the backdrop shows there.
        let roundCorner = pixel(image, x: 42, y: 42)
        #expect(roundCorner.blue > 200, "the free corner should still be rounded, got \(roundCorner)")
    }

    // MARK: - Gradients

    @Test("A three-stop gradient passes through its middle color")
    func gradientUsesItsMiddleStop() throws {
        let ramp = BeautifyGradient(
            start: AnnotationColor(red: 1, green: 0, blue: 0),
            middle: AnnotationColor(red: 0, green: 1, blue: 0),
            end: AnnotationColor(red: 0, green: 0, blue: 1),
            angleDegrees: 90
        )
        let spec = BeautifySpec(
            padding: .points(60),
            cornerRadius: .zero,
            backdrop: .gradient(ramp),
            shadow: .none,
            aspect: .original,
            alignment: .center,
            sticksToEdges: false
        )
        let image = try renderer.render(baseImage: makeOpaqueImage(), document: document(spec))

        // The leftmost column, halfway down: gradient only, no capture.
        let middle = pixel(image, x: 1, y: image.height / 2)
        #expect(middle.green > 150, "the middle stop should show, got \(middle)")
        #expect(middle.red < 150)
        #expect(middle.blue < 150)
    }

    @Test("A gradient runs the way its angle says", arguments: [CGFloat(90), 270])
    func gradientAngle(angle: CGFloat) throws {
        let ramp = BeautifyGradient(
            start: AnnotationColor(red: 1, green: 0, blue: 0),
            end: AnnotationColor(red: 0, green: 0, blue: 1),
            angleDegrees: angle
        )
        let spec = BeautifySpec(
            padding: .points(60),
            cornerRadius: .zero,
            backdrop: .gradient(ramp),
            shadow: .none,
            aspect: .original,
            alignment: .center,
            sticksToEdges: false
        )
        let image = try renderer.render(baseImage: makeOpaqueImage(), document: document(spec))

        let top = pixel(image, x: 1, y: 1)
        let bottom = pixel(image, x: 1, y: image.height - 2)
        if angle == 90 {
            #expect(top.red > top.blue, "90° should start red at the top, got \(top)")
            #expect(bottom.blue > bottom.red)
        } else {
            #expect(top.blue > top.red, "270° should be the other way round, got \(top)")
            #expect(bottom.red > bottom.blue)
        }
    }
}

/// The four-corner path builder (docs/09 U1.1).
@Suite("Rounded corner path")
struct RoundedCornerPathTests {
    private let rect = CGRect(x: 0, y: 0, width: 100, height: 60)

    @Test("A zero radius is a plain rectangle")
    func squareIsRectangular() {
        let path = RoundedCornerPath.path(in: rect, corners: .square)
        #expect(path.boundingBox == rect)
    }

    @Test("A rounded path still fills its rect's bounds")
    func roundedKeepsBounds() {
        let path = RoundedCornerPath.path(in: rect, corners: BeautifyCorners(uniform: 20))
        #expect(path.boundingBox.width == rect.width)
        #expect(path.boundingBox.height == rect.height)
    }

    /// The corner that is rounded is the one that is outside the path; the square one is
    /// inside it. That is the whole behaviour, and it is checkable without pixels.
    @Test("A mixed path rounds only the corners it is told to")
    func mixedCorners() {
        let corners = BeautifyCorners(topLeading: 20, topTrailing: 0, bottomTrailing: 0, bottomLeading: 20)
        let path = RoundedCornerPath.path(in: rect, corners: corners)

        #expect(!path.contains(CGPoint(x: 1, y: 1)), "the top-left is rounded away")
        #expect(path.contains(CGPoint(x: rect.maxX - 1, y: 1)), "the top-right is square")
        #expect(path.contains(CGPoint(x: rect.maxX - 1, y: rect.maxY - 1)), "as is the bottom-right")
        #expect(!path.contains(CGPoint(x: 1, y: rect.maxY - 1)), "the bottom-left is rounded away")
    }

    @Test("An oversized radius is clamped rather than inverting the path")
    func oversizedRadius() {
        let path = RoundedCornerPath.path(in: rect, corners: BeautifyCorners(uniform: 900))
        #expect(path.boundingBox.width == rect.width)
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
    }
}

/// The wallpaper decode cache (docs/09 U1.1).
@Suite("Wallpaper cache")
struct WallpaperCacheTests {
    @Test("A request rounds up into a bucket", arguments: [
        (CGFloat(1), 256),
        (256, 256),
        (257, 512),
        (1000, 1024),
        (5000, 4096)
    ])
    func bucketing(requested: CGFloat, expected: Int) {
        #expect(WallpaperCache.bucket(for: requested) == expected)
    }

    /// The point of bucketing: a slider drag changes the canvas by a pixel or two per
    /// frame, and every one of those frames must land on the same decode.
    @Test("Nearby sizes share a bucket, so a slider drag decodes once")
    func nearbySizesShareABucket() {
        let sizes: [CGFloat] = [1000, 1001, 1002, 1010, 1024]
        let buckets = Set(sizes.map { WallpaperCache.bucket(for: $0) })
        #expect(buckets.count == 1)
    }

    @Test("A request beyond the largest bucket is capped rather than unbounded")
    func hugeRequestIsCapped() {
        #expect(WallpaperCache.buckets == [256, 512, 1024, 2048, 4096])
        #expect(WallpaperCache.bucket(for: 100_000) == 4096)
        #expect(WallpaperCache.bucket(for: 8192) == 4096)
    }

    @Test("A file that is not an image is refused, not crashed into")
    func unreadableFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-wall-\(UUID().uuidString).png")
        try Data("not a png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(WallpaperCache().image(at: url.path, longestEdge: 512) == nil)
    }

    @Test("A wallpaper decodes no larger than its bucket")
    func decodesAtTheBucketSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-wall-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let context = CGContext(
            data: nil,
            width: 2000,
            height: 1200,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let source = context.makeImage() else {
            Issue.record("could not build a test wallpaper")
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            Issue.record("could not write a test wallpaper")
            return
        }
        CGImageDestinationAddImage(destination, source, nil)
        #expect(CGImageDestinationFinalize(destination))

        let cache = WallpaperCache()
        let decoded = try #require(cache.image(at: url.path, longestEdge: 300))
        #expect(max(decoded.width, decoded.height) <= 512, "a 2000px wallpaper must not be decoded whole")

        // And the second request is the same object, not a second decode.
        let again = try #require(cache.image(at: url.path, longestEdge: 300))
        #expect(decoded === again)
    }
}
