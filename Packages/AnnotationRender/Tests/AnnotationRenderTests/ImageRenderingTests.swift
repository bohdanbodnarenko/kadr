import AnnotationModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnnotationRender

/// Rendering an inserted image (docs/03 §3 P2, docs/06 M24).
@Suite("Image rendering")
struct ImageRenderingTests {
    /// A solid-colour PNG. Default blue, so "did it draw?" is one pixel read against a red canvas.
    private func makePNG(
        width: Int = 20,
        height: Int = 20,
        red: CGFloat = 0,
        green: CGFloat = 0,
        blue: CGFloat = 1
    ) -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not create a test bitmap")
        }
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else {
            fatalError("Could not create a test image")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            fatalError("Could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("Could not encode the test PNG")
        }
        return data as Data
    }

    private func makeBase(width: Int = 100, height: Int = 100) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not create a test bitmap")
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            fatalError("Could not create a test image")
        }
        return image
    }

    private struct Sample {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> Sample {
        // Explicitly allocated, not `&someArray`: a `CGContext` keeps the pointer it is
        // given and writes through it during `draw` — past the end of the inout access
        // an array would give it, which is undefined behaviour and does crash.
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

    @Test("An inserted image is drawn where the document says it is")
    func drawsAtItsRect() throws {
        var document = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 100, height: 100), scale: 1)
        )
        document.add(.image(ImageSpec(
            pngData: makePNG(),
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            hasShadow: false
        )))

        let rendered = try AnnotationExportRenderer().render(baseImage: makeBase(), document: document)

        // Inside the insert: blue. Outside it: the red base.
        let inside = pixel(rendered, x: 30, y: 30)
        #expect(inside.blue > 200)
        #expect(inside.red < 60)

        let outside = pixel(rendered, x: 80, y: 80)
        #expect(outside.red > 200)
        #expect(outside.blue < 60)
    }

    @Test("Opacity is honoured, so an insert can be laid over the capture")
    func opacity() throws {
        var document = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 100, height: 100), scale: 1)
        )
        document.add(.image(ImageSpec(
            pngData: makePNG(),
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            opacity: 0.5,
            hasShadow: false
        )))

        let rendered = try AnnotationExportRenderer().render(baseImage: makeBase(), document: document)
        let blended = pixel(rendered, x: 30, y: 30)
        #expect(blended.blue > 60, "the insert should be visible")
        #expect(blended.red > 60, "the capture should show through")
    }

    @Test("Nothing is drawn for an image that cannot be decoded")
    func undecodableImage() throws {
        var document = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 100, height: 100), scale: 1)
        )
        document.add(.image(ImageSpec(
            pngData: Data([0x01, 0x02]),
            rect: CGRect(x: 10, y: 10, width: 40, height: 40)
        )))

        let rendered = try AnnotationExportRenderer().render(baseImage: makeBase(), document: document)
        #expect(pixel(rendered, x: 30, y: 30).red > 200, "the capture should be untouched")
    }

    @Test("Decoding the same image twice reuses the decode")
    func cachesDecodes() {
        let png = makePNG()
        let first = ImageRendering.decode(png)
        let second = ImageRendering.decode(png)
        #expect(first != nil)
        #expect(first === second)
    }

    @Test("A rebuild asking for the same bytes again does not hash them again")
    func sameBufferIsNotRehashed() throws {
        let cache = ImageCache()
        let png = makePNG()
        let first = try #require(cache.image(for: png))
        let copyOfValue = png // Same buffer: `Data` is copy-on-write.
        let second = try #require(cache.image(for: copyOfValue))
        #expect(first === second)
        #expect(cache.hashCount == 1)

        // Equal bytes in a different buffer are hashed, and still find the same decode.
        let rebuilt = Data(Array(png))
        let third = try #require(cache.image(for: rebuilt))
        #expect(third === first)
        #expect(cache.hashCount == 2)
    }

    @Test("Clearing the cache forgets decodes")
    func removeAllForgets() throws {
        let cache = ImageCache()
        let png = makePNG()
        let first = try #require(cache.image(for: png))
        cache.removeAll()
        let second = try #require(cache.image(for: png))
        #expect(first !== second)
        #expect(cache.hashCount == 2)
    }

    @Test("Two different PNGs of the same size are not returned as each other")
    func distinctImagesAreNotAliased() throws {
        // Darwin's Data.hashValue hashes a bounded prefix. Two same-size PNGs share a
        // header; keying the cache on that used to hand back the wrong image (docs/10 R2.4).
        let blue = makePNG(red: 0, green: 0, blue: 1)
        let red = makePNG(red: 1, green: 0, blue: 0)
        let blueImage = try #require(ImageRendering.decode(blue))
        let redImage = try #require(ImageRendering.decode(red))
        #expect(blueImage !== redImage)

        let blueAgain = try #require(ImageRendering.decode(blue))
        #expect(blueAgain === blueImage)
        let sample = pixel(blueAgain, x: 1, y: 1)
        #expect(sample.blue > 200)
        #expect(sample.red < 60)
    }
}
