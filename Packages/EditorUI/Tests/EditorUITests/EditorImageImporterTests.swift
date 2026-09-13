import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EditorUI

@Suite("Image importer")
struct EditorImageImporterTests {
    @Test("A PNG file round-trips into composition bytes")
    func loadsPNGFile() throws {
        let image = try #require(makeImage(width: 12, height: 8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-import-\(UUID().uuidString).png")
        try writePNG(image, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try #require(EditorImageImporter.png(from: url))
        #expect(imported.pixelSize == CGSize(width: 12, height: 8))
        #expect(!imported.data.isEmpty)

        let fromImage = try #require(EditorImageImporter.png(from: image))
        #expect(fromImage.pixelSize == imported.pixelSize)
    }

    @Test("A missing file imports nothing")
    func missingFile() {
        let url = URL(fileURLWithPath: "/tmp/kadr-does-not-exist-\(UUID().uuidString).png")
        #expect(EditorImageImporter.png(from: url) == nil)
    }
}

private func makeImage(width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}
