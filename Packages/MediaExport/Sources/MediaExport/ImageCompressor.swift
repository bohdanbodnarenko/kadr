import CoreGraphics
import Foundation
import ImageIO
import os
import Shared
import UniformTypeIdentifiers

/// How small, and in what format (docs/09 U2.4).
public struct CompressionOptions: Sendable, Hashable {
    /// The size to aim for. Nil means "as small as the quality floor allows".
    public var targetBytes: Int?
    /// The container. HEIC is roughly half the size of JPEG at the same quality, and every
    /// Mac since 2017 reads it — but a file going to a stranger's Windows machine had
    /// better be a JPEG, so it is a choice rather than a default.
    public var format: CompressedImageFormat
    /// The worst quality worth producing. Below this the artefacts are the message.
    public var minimumQuality: Double
    /// The best quality to bother trying: a screenshot re-encoded at 1.0 is usually larger
    /// than the PNG it came from.
    public var maximumQuality: Double

    public init(
        targetBytes: Int? = nil,
        format: CompressedImageFormat = .heic,
        minimumQuality: Double = 0.35,
        maximumQuality: Double = 0.9
    ) {
        self.targetBytes = targetBytes.map { max($0, 1) }
        self.format = format
        self.minimumQuality = min(max(minimumQuality, 0.05), 0.95)
        self.maximumQuality = min(max(maximumQuality, self.minimumQuality), 1)
    }

    /// The default offer: about a quarter of a megabyte, which is small enough to paste
    /// into anything and large enough to still read a screenshot.
    public static let standard = CompressionOptions(targetBytes: 256 * 1024)
}

/// What a compression produced.
public struct CompressionResult: Sendable, Hashable {
    public var data: Data
    public var format: CompressedImageFormat
    /// The quality the search settled on, for the log and for the badge's tooltip.
    public var quality: Double
    public var originalBytes: Int

    public init(data: Data, format: CompressedImageFormat, quality: Double, originalBytes: Int) {
        self.data = data
        self.format = format
        self.quality = quality
        self.originalBytes = originalBytes
    }

    public var compressedBytes: Int {
        data.count
    }

    /// How much smaller, as a fraction. Negative when the "compressed" file is larger,
    /// which happens to flat screenshots and is worth telling the user rather than hiding.
    public var savingsFraction: Double {
        guard originalBytes > 0 else { return 0 }
        return 1 - Double(compressedBytes) / Double(originalBytes)
    }

    public var isWorthwhile: Bool {
        compressedBytes < originalBytes
    }
}

public enum CompressionError: Error, Equatable, Sendable {
    case unreadableImage
    case encodingFailed
}

/// Re-encodes a capture smaller (docs/09 U2.4).
///
/// The interesting part is hitting a size target. Quality and file size are related by a
/// curve nobody can predict from the image — a screenshot of a text editor and a photograph
/// of a beach behave completely differently — so the only honest way to hit a target is to
/// encode, measure, and adjust.
///
/// A binary search rather than a linear walk: the curve is monotonic (more quality is never
/// fewer bytes), so halving the interval converges in a handful of encodes where stepping
/// through qualities would take dozens. Bounded iterations, because the last few percent of
/// precision costs as many encodes as the first ninety.
public struct ImageCompressor: Sendable {
    private let logger = KadrLog.logger(.capture)

    /// How many encodes the search may spend. Six halvings resolve quality to under two
    /// per cent, which is far finer than the size difference anybody notices.
    public static let maximumAttempts = 6

    public init() {}

    /// Compresses an image already in memory.
    public func compress(
        _ image: CGImage,
        originalBytes: Int,
        options: CompressionOptions = .standard
    ) throws -> CompressionResult {
        guard let target = options.targetBytes else {
            let quality = options.maximumQuality
            guard let data = Self.encode(image, format: options.format, quality: quality) else {
                throw CompressionError.encodingFailed
            }
            return CompressionResult(
                data: data,
                format: options.format,
                quality: quality,
                originalBytes: originalBytes
            )
        }
        // Aiming past the original is pointless: a "compressed" copy larger than what it
        // came from is not a smaller file, whatever the target said. A PNG of a
        // screenshot is often already smaller than any lossy re-encode of it, and the
        // request has to mean "smaller than this" rather than "under this number".
        let effective = originalBytes > 1 ? min(target, originalBytes - 1) : target
        return try search(image, target: effective, originalBytes: originalBytes, options: options)
    }

    /// Compresses a file, reporting its original size.
    public func compress(
        fileAt url: URL,
        options: CompressionOptions = .standard
    ) throws -> CompressionResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CompressionError.unreadableImage
        }
        let originalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return try compress(image, originalBytes: originalBytes, options: options)
    }

    /// Binary search for the highest quality that still fits the target.
    ///
    /// Highest rather than closest: a file that comes in under the target is a success, and
    /// between two successes the better-looking one is the right answer. The best result
    /// seen is kept throughout, so a search that never finds a fit still returns the
    /// smallest thing it made rather than nothing.
    private func search(
        _ image: CGImage,
        target: Int,
        originalBytes: Int,
        options: CompressionOptions
    ) throws -> CompressionResult {
        var low = options.minimumQuality
        var high = options.maximumQuality
        var best: CompressionResult?
        var smallest: CompressionResult?

        for _ in 0 ..< Self.maximumAttempts {
            let quality = (low + high) / 2
            guard let data = Self.encode(image, format: options.format, quality: quality) else {
                throw CompressionError.encodingFailed
            }
            let attempt = CompressionResult(
                data: data,
                format: options.format,
                quality: quality,
                originalBytes: originalBytes
            )
            if smallest.map({ attempt.compressedBytes < $0.compressedBytes }) ?? true {
                smallest = attempt
            }

            if attempt.compressedBytes <= target {
                // It fits: keep it and try to look better.
                best = attempt
                low = quality
            } else {
                high = quality
            }
        }

        guard let result = best ?? smallest else { throw CompressionError.encodingFailed }
        let saved = Int(result.savingsFraction * 100)
        let bytes = result.compressedBytes
        logger.info("Compressed to \(bytes, privacy: .public) bytes, \(saved, privacy: .public)% smaller")
        return result
    }

    /// One encode at one quality.
    static func encode(_ image: CGImage, format: CompressedImageFormat, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            format.contentType.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
