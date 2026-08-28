import AnnotationModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnnotationRender

/// Background removal (docs/03 §3 P3, docs/06 M23).
///
/// The thing worth proving is that the background is actually *gone* from the pixels —
/// a cut-out that merely looks right in the editor but exports the original background
/// would be the same class of bug as a removable blur.
@Suite("Subject lift")
struct SubjectLiftTests {
    private let width = 40
    private let height = 20

    /// A solid red image to cut a subject out of.
    private func makeImage() -> CGImage {
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

    /// A mask whose left half is subject (white) and right half background (black).
    private func makeMaskPNG() -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            fatalError("Could not create a test mask")
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))

        guard let mask = context.makeImage() else {
            fatalError("Could not create a test mask image")
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
        CGImageDestinationAddImage(destination, mask, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("Could not encode the test mask")
        }
        return data as Data
    }

    /// One sampled pixel. A struct rather than a tuple so the fields have names at the
    /// assertion site, where "is `.3` the alpha?" is exactly the wrong question to have.
    private struct Sample {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    /// Reads one pixel's RGBA out of an image.
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

    @Test("The subject survives and the background becomes transparent")
    func transparentBackground() {
        let spec = SubjectLiftSpec(maskPNG: makeMaskPNG(), background: .transparent)
        let result = SubjectLiftCompositor().apply(spec, to: makeImage())

        let subject = pixel(result, x: 5, y: 10)
        #expect(subject.alpha > 200)
        #expect(subject.red > 200)

        let background = pixel(result, x: 35, y: 10)
        #expect(background.alpha < 40, "the background should be gone, not merely covered")
    }

    @Test("A colour background fills what the subject does not cover")
    func colourBackground() {
        let spec = SubjectLiftSpec(
            maskPNG: makeMaskPNG(),
            background: .color(AnnotationColor(red: 0, green: 0, blue: 1))
        )
        let result = SubjectLiftCompositor().apply(spec, to: makeImage())

        let background = pixel(result, x: 35, y: 10)
        #expect(background.alpha > 200)
        #expect(background.blue > 200)
        #expect(background.red < 40)

        let subject = pixel(result, x: 5, y: 10)
        #expect(subject.red > 200)
    }

    @Test("The image keeps its size")
    func sizeIsPreserved() {
        let spec = SubjectLiftSpec(maskPNG: makeMaskPNG())
        let result = SubjectLiftCompositor().apply(spec, to: makeImage())
        #expect(result.width == width)
        #expect(result.height == height)
    }

    /// A mask that cannot be read must cost the user their cut-out, not their screenshot.
    @Test("An unreadable mask leaves the image alone")
    func unreadableMask() {
        let spec = SubjectLiftSpec(maskPNG: Data([0x00, 0x01, 0x02]))
        let image = makeImage()
        let result = SubjectLiftCompositor().apply(spec, to: image)
        #expect(result.width == image.width)
        #expect(pixel(result, x: 35, y: 10).alpha > 200)
    }

    @Test("Export applies the lift, including to a copy without annotations")
    func exportAppliesTheLift() throws {
        var document = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: width, height: height), scale: 1)
        )
        document.setSubjectLift(SubjectLiftSpec(maskPNG: makeMaskPNG()))

        for includeAnnotations in [true, false] {
            let rendered = try AnnotationExportRenderer().render(
                baseImage: makeImage(),
                document: document,
                includeAnnotations: includeAnnotations
            )
            #expect(pixel(rendered, x: 35, y: 10).alpha < 40)
            #expect(pixel(rendered, x: 5, y: 10).alpha > 200)
        }
    }
}
