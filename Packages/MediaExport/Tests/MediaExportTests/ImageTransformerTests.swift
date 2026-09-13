import CoreGraphics
import Foundation
import ImageIO
import Shared
import Testing
@testable import MediaExport

private func makeImage(width: Int, height: Int) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        fatalError("Could not create a test bitmap")
    }
    return image
}

@Suite("Image transforms")
struct ImageTransformerTests {
    private let transformer = ImageTransformer()

    @Test("A clockwise rotation swaps width and height")
    func rotateSwapsSize() throws {
        let rotated = try transformer.apply(.rotateClockwise, to: makeImage(width: 40, height: 20))
        #expect(rotated.width == 20)
        #expect(rotated.height == 40)
    }

    @Test("Four clockwise rotations restore the original size")
    func rotateFourTimes() throws {
        var image = makeImage(width: 40, height: 20)
        for _ in 0 ..< 4 {
            image = try transformer.apply(.rotateClockwise, to: image)
        }
        #expect(image.width == 40)
        #expect(image.height == 20)
    }

    @Test("A horizontal flip keeps the size")
    func flipKeepsSize() throws {
        let flipped = try transformer.apply(.flipHorizontal, to: makeImage(width: 40, height: 20))
        #expect(flipped.width == 40)
        #expect(flipped.height == 20)
    }

    @Test("A vertical flip keeps the size")
    func flipVerticalKeepsSize() throws {
        let flipped = try transformer.apply(.flipVertical, to: makeImage(width: 40, height: 20))
        #expect(flipped.width == 40)
        #expect(flipped.height == 20)
    }

    @Test("Retina downscale halves both edges")
    func downscaleHalves() throws {
        let scaled = try transformer.apply(
            .downscaleRetina(.retina),
            to: makeImage(width: 40, height: 20)
        )
        #expect(scaled.width == 20)
        #expect(scaled.height == 10)
    }

    @Test("Rewriting a PNG on disk updates its pixel size")
    func rewriteFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-xform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shot.png")
        let data = try ImageEncoder().encode(makeImage(width: 40, height: 20), options: EncodingOptions())
        try data.write(to: url)

        let size = try transformer.rewrite(url, applying: .rotateClockwise)
        #expect(size == PixelSize(width: 20, height: 40))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Format follows the file extension", arguments: [
        ("shot.png", ImageFormat.png),
        ("shot.jpg", ImageFormat.jpeg),
        ("shot.jpeg", ImageFormat.jpeg),
        ("shot.heic", ImageFormat.heic)
    ])
    func formatFromExtension(name: String, expected: ImageFormat) {
        #expect(ImageTransformer.format(from: URL(fileURLWithPath: "/tmp/\(name)")) == expected)
    }
}
