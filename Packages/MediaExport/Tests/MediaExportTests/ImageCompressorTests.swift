import CoreGraphics
import Foundation
import ImageIO
import Shared
import Testing
import UniformTypeIdentifiers
@testable import MediaExport

/// Re-encoding a capture smaller (docs/09 U2.4).
///
/// The interesting part is hitting a size target: quality and file size are related by a
/// curve nobody can predict from the image, so the only honest way is to encode, measure
/// and adjust. These tests are about that search behaving.
@Suite("Image compressor")
struct ImageCompressorTests {
    /// A busy image, so compression has something to do. A flat fill encodes to almost
    /// nothing at any quality and would make every target trivially reachable.
    private func makeBusyImage(size: Int = 600) -> CGImage {
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
        var generator = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: size, by: 3) {
            for x in stride(from: 0, to: size, by: 3) {
                context.setFillColor(
                    red: CGFloat.random(in: 0 ... 1, using: &generator),
                    green: CGFloat.random(in: 0 ... 1, using: &generator),
                    blue: CGFloat.random(in: 0 ... 1, using: &generator),
                    alpha: 1
                )
                context.fill(CGRect(x: x, y: y, width: 3, height: 3))
            }
        }
        guard let image = context.makeImage() else {
            fatalError("Could not create a test capture")
        }
        return image
    }

    private func makeFlatImage(size: Int = 400) -> CGImage {
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
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else {
            fatalError("Could not create a test capture")
        }
        return image
    }

    // MARK: - Hitting the target

    @Test("A generous target is met with room to spare")
    func generousTarget() throws {
        let image = makeBusyImage()
        let result = try ImageCompressor().compress(
            image,
            originalBytes: 5_000_000,
            options: CompressionOptions(targetBytes: 500_000)
        )
        #expect(result.compressedBytes <= 500_000)
        #expect(result.compressedBytes > 0)
    }

    /// Between two results that both fit, the better-looking one is the right answer — so
    /// the search keeps the highest quality that fits rather than the smallest file.
    @Test("It settles on the best quality that still fits")
    func picksTheBestQualityThatFits() throws {
        let image = makeBusyImage()
        let compressor = ImageCompressor()
        let target = 200_000

        let result = try compressor.compress(
            image,
            originalBytes: 5_000_000,
            options: CompressionOptions(targetBytes: target)
        )
        #expect(result.compressedBytes <= target)

        // A noticeably higher quality should overshoot, or the search stopped too early.
        let higher = try #require(ImageCompressor.encode(
            image,
            format: .heic,
            quality: min(result.quality + 0.2, 1)
        ))
        #expect(higher.count > result.compressedBytes)
    }

    /// A "compressed" copy larger than what it came from is not a smaller file, whatever
    /// the target said — so a target past the original is capped at it.
    @Test("A target larger than the original still produces something smaller")
    func targetLargerThanTheOriginal() throws {
        // The original has to be a size the image can actually get under: the fixture is
        // random noise, and no quality setting makes noise tiny.
        let result = try ImageCompressor().compress(
            makeBusyImage(),
            originalBytes: 400_000,
            options: CompressionOptions(targetBytes: 10_000_000)
        )
        #expect(result.compressedBytes < 400_000)
        #expect(result.isWorthwhile)
    }

    /// A target nothing can reach must still produce the smallest thing it made, rather
    /// than failing and leaving the user with nothing.
    @Test("An impossible target still returns the smallest result")
    func impossibleTarget() throws {
        let result = try ImageCompressor().compress(
            makeBusyImage(),
            originalBytes: 5_000_000,
            options: CompressionOptions(targetBytes: 1)
        )
        #expect(result.compressedBytes > 1, "nothing can hit one byte")
        #expect(result.compressedBytes < 5_000_000)
    }

    @Test("With no target it encodes once at the ceiling")
    func noTarget() throws {
        let result = try ImageCompressor().compress(
            makeBusyImage(),
            originalBytes: 1000,
            options: CompressionOptions(targetBytes: nil, maximumQuality: 0.8)
        )
        #expect(result.quality == 0.8)
    }

    // MARK: - Reporting

    @Test("Savings are reported as a fraction of the original")
    func savings() {
        let result = CompressionResult(
            data: Data(count: 250),
            format: .heic,
            quality: 0.6,
            originalBytes: 1000
        )
        #expect(abs(result.savingsFraction - 0.75) < 0.001)
        #expect(result.isWorthwhile)
    }

    /// A screenshot of flat colour re-encodes larger than its PNG. Saying so beats putting
    /// a bigger file on the clipboard and calling it compressed.
    @Test("A result that is larger says so rather than pretending")
    func notWorthwhile() {
        let result = CompressionResult(
            data: Data(count: 2000),
            format: .heic,
            quality: 0.6,
            originalBytes: 1000
        )
        #expect(!result.isWorthwhile)
        #expect(result.savingsFraction < 0)
    }

    @Test("A zero-byte original does not divide by zero")
    func zeroOriginal() {
        let result = CompressionResult(data: Data(count: 10), format: .jpeg, quality: 0.5, originalBytes: 0)
        #expect(result.savingsFraction == 0)
    }

    // MARK: - Formats and bounds

    @Test("Both formats encode", arguments: CompressedImageFormat.allCases)
    func bothFormats(format: CompressedImageFormat) throws {
        let result = try ImageCompressor().compress(
            makeFlatImage(),
            originalBytes: 100_000,
            options: CompressionOptions(targetBytes: 50000, format: format)
        )
        #expect(result.format == format)
        #expect(!result.data.isEmpty)
    }

    @Test("Quality bounds are ordered however they are given")
    func boundsAreOrdered() {
        let options = CompressionOptions(minimumQuality: 0.9, maximumQuality: 0.2)
        #expect(options.minimumQuality <= options.maximumQuality)
    }

    @Test("Absurd bounds are clamped into the usable range")
    func boundsAreClamped() {
        let options = CompressionOptions(minimumQuality: -5, maximumQuality: 99)
        #expect(options.minimumQuality > 0)
        #expect(options.maximumQuality <= 1)
    }

    @Test("A negative target is treated as the smallest possible one")
    func negativeTarget() {
        #expect(CompressionOptions(targetBytes: -100).targetBytes == 1)
    }

    /// The search is bounded: the last few per cent of precision costs as many encodes as
    /// the first ninety, and the card is waiting.
    @Test("The search is bounded")
    func searchIsBounded() {
        #expect(ImageCompressor.maximumAttempts <= 8)
    }

    // MARK: - Files

    @Test("A file is read, compressed and reports its original size")
    func compressingAFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-compress-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            Issue.record("could not write a test capture")
            return
        }
        CGImageDestinationAddImage(destination, makeBusyImage(), nil)
        #expect(CGImageDestinationFinalize(destination))

        // A target more generous than the original: the useful answer is still "smaller
        // than the original", not "under the number you typed".
        let result = try ImageCompressor().compress(
            fileAt: url,
            options: CompressionOptions(targetBytes: 300_000)
        )
        #expect(result.originalBytes > 0)
        #expect(result.compressedBytes < result.originalBytes)
    }

    @Test("A file that is not an image is refused, not crashed into")
    func unreadableFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-compress-\(UUID().uuidString).png")
        try Data("not a png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: CompressionError.unreadableImage) {
            try ImageCompressor().compress(fileAt: url)
        }
    }
}
