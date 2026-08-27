import CoreGraphics
import Foundation
import ImageIO
import Shared
import Testing
@testable import MediaExport

private func makeImage(width: Int = 40, height: Int = 20, opaque: Bool = false) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
    ) else {
        fatalError("Could not create a test bitmap context")
    }
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        fatalError("Could not create a test image")
    }
    return image
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Encoding captures")
struct ImageEncoderTests {
    private let encoder = ImageEncoder()

    @Test("Every writable format encodes to data ImageIO can read back", arguments: ImageFormat.writable)
    func encodesEveryFormat(format: ImageFormat) throws {
        let data = try encoder.encode(makeImage(), options: EncodingOptions(format: format))
        #expect(data.isEmpty == false)

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 40)
        #expect(decoded.height == 20)
    }

    @Test("A Retina capture is tagged 144 dpi so it displays at its true size")
    func retinaDPITag() throws {
        let data = try encoder.encode(
            makeImage(),
            options: EncodingOptions(format: .png, scale: .retina)
        )
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyDPIWidth] as? Double == 144)
    }

    @Test("A 1× capture stays at 72 dpi")
    func nonRetinaDPITag() {
        let properties = encoder.properties(for: EncodingOptions(scale: .oneToOne))
        #expect(properties[kCGImagePropertyDPIWidth] as? Double == 72)
    }

    @Test("Downscaling a Retina capture halves it and puts the DPI back to 72")
    func downscale() throws {
        let options = EncodingOptions(format: .png, scale: .retina, downscaleToOneToOne: true)
        let data = try encoder.encode(makeImage(width: 40, height: 20), options: options)

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 20)
        #expect(decoded.height == 10)
        #expect(encoder.properties(for: options)[kCGImagePropertyDPIWidth] as? Double == 72)
    }

    @Test("Downscaling a 1× capture leaves it alone")
    func downscaleNoOp() throws {
        let image = makeImage()
        let result = try encoder.downscale(image, by: 1)
        #expect(result.width == image.width)
    }

    @Test("Quality only reaches lossy formats")
    func qualityOnlyForLossy() {
        let png = ImageEncoder().properties(for: EncodingOptions(format: .png, quality: 0.5))
        let jpeg = ImageEncoder().properties(for: EncodingOptions(format: .jpeg, quality: 0.5))

        #expect(png[kCGImageDestinationLossyCompressionQuality] == nil)
        #expect(jpeg[kCGImageDestinationLossyCompressionQuality] as? Double == 0.5)
    }

    @Test("Quality is clamped rather than passed through to ImageIO")
    func qualityClamped() {
        #expect(EncodingOptions(quality: 5).quality == 1)
        #expect(EncodingOptions(quality: -1).quality == 0)
    }

    @Test("macOS cannot write WebP, so asking for it fails loudly rather than silently")
    func webPIsNotWritable() {
        // Read-only support: ImageIO has a WebP decoder and no encoder. The PRD lists
        // WebP as an export format; this is the platform's answer, surfaced rather than
        // hidden behind an empty file.
        #expect(ImageFormat.webp.isWritable == false)
        #expect(ImageFormat.writable.contains(.webp) == false)
        #expect(throws: ExportError.unsupportedFormat(.webp)) {
            try ImageEncoder().encode(makeImage(), options: EncodingOptions(format: .webp))
        }
    }

    @Test("The formats macOS can write are the ones offered")
    func writableFormats() {
        #expect(ImageFormat.writable.contains(.png))
        #expect(ImageFormat.writable.contains(.jpeg))
        #expect(ImageFormat.writable.contains(.heic))
    }

    @Test("Formats know whether they can carry transparency", arguments: [
        (ImageFormat.png, true), (.heic, true), (.webp, true), (.jpeg, false)
    ])
    func transparencySupport(format: ImageFormat, supports: Bool) {
        #expect(format.supportsTransparency == supports)
    }
}

@Suite("Writing captures to disk")
struct CaptureFileWriterTests {
    private let writer = CaptureFileWriter()

    @Test("A capture is written where the template says")
    func writesFile() throws {
        let directory = temporaryDirectory()
        let url = try writer.write(
            makeImage(),
            to: directory,
            template: FilenameTemplate("shot"),
            options: EncodingOptions(format: .png)
        )

        #expect(url.lastPathComponent == "shot.png")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A second capture with the same name never overwrites the first")
    func neverOverwrites() throws {
        let directory = temporaryDirectory()
        let template = FilenameTemplate("shot")

        let first = try writer.write(makeImage(), to: directory, template: template)
        let second = try writer.write(makeImage(), to: directory, template: template)
        let third = try writer.write(makeImage(), to: directory, template: template)

        #expect(first.lastPathComponent == "shot.png")
        #expect(second.lastPathComponent == "shot (2).png")
        #expect(third.lastPathComponent == "shot (3).png")
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test("A template with its own counter uses it instead of a suffix")
    func templateCounter() throws {
        let directory = temporaryDirectory()
        let template = FilenameTemplate("shot-{counter}")

        let first = try writer.write(makeImage(), to: directory, template: template)
        let second = try writer.write(makeImage(), to: directory, template: template)

        #expect(first.lastPathComponent == "shot-1.png")
        #expect(second.lastPathComponent == "shot-2.png")
    }

    @Test("A missing directory is created rather than failing the write")
    func createsDirectory() throws {
        let directory = temporaryDirectory().appendingPathComponent("nested/deeper", isDirectory: true)
        let url = try writer.write(makeImage(), to: directory, template: FilenameTemplate("shot"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("The extension follows the format", arguments: ImageFormat.writable)
    func extensionFollowsFormat(format: ImageFormat) throws {
        let directory = temporaryDirectory()
        let url = try writer.write(
            makeImage(),
            to: directory,
            template: FilenameTemplate("shot"),
            options: EncodingOptions(format: format)
        )
        #expect(url.pathExtension == format.fileExtension)
    }
}
