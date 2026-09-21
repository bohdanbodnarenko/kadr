import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

/// A capture that is red on top and blue underneath, so an export that comes out upside
/// down is unmistakable.
private func makeTopRedImage(width: Int = 40, height: Int = 40) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap context")
    }
    // A bitmap context is y-up, so the *top* of the picture is the high y.
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    guard let image = context.makeImage() else { fatalError("Could not create a test image") }
    return image
}

/// The RGBA of one pixel, counted from the top-left the way a viewer shows it.
private func pixel(of image: CGImage, x: Int, fromTop y: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.draw(
            image,
            in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height)
        )
    }
    return bytes
}

@Suite("Export keeps the picture the right way up")
struct ExportOrientationTests {
    private let renderer = AnnotationExportRenderer()
    private let red: [UInt8] = [255, 0, 0, 255]
    private let blue: [UInt8] = [0, 0, 255, 255]

    private func document(_ commands: [AnnotationCommand] = []) -> AnnotationDocument {
        AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 40, height: 40), scale: 1),
            commands: commands
        )
    }

    @Test("A plain export keeps the top of the capture on top")
    func plainExportIsUpright() throws {
        let image = try renderer.render(baseImage: makeTopRedImage(), document: document())
        #expect(pixel(of: image, x: 20, fromTop: 5) == red)
        #expect(pixel(of: image, x: 20, fromTop: 35) == blue)
    }

    @Test("A beautified export keeps the top of the capture on top")
    func beautifiedExportIsUpright() throws {
        let spec = BeautifySpec(
            padding: .points(10),
            cornerRadius: .zero,
            backdrop: .solid(AnnotationColor(red: 0, green: 1, blue: 0)),
            shadow: .none,
            aspect: .original,
            alignment: .center,
            sticksToEdges: false
        )
        let image = try renderer.render(baseImage: makeTopRedImage(), document: document([.beautify(spec)]))
        // 10 points of backdrop all round, so the card spans 10 ..< 50 of a 60-point canvas.
        #expect(pixel(of: image, x: 30, fromTop: 15) == red)
        #expect(pixel(of: image, x: 30, fromTop: 45) == blue)
    }

    @Test("A camera export keeps the top of the capture on top")
    func cameraExportIsUpright() throws {
        let image = try renderer.render(baseImage: makeTopRedImage(), document: document([.camera(.identity)]))
        #expect(pixel(of: image, x: 20, fromTop: 5) == red)
        #expect(pixel(of: image, x: 20, fromTop: 35) == blue)
    }
}
