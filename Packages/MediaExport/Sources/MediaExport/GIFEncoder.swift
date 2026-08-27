import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import os
import Shared
import UniformTypeIdentifiers

/// How a GIF should be encoded (docs/03 §1.8).
public struct GIFOptions: Sendable, Hashable {
    /// Frames per second. Capped at 50 because the GIF format stores delays in
    /// hundredths of a second, so anything faster cannot be represented evenly and
    /// players round it unpredictably.
    public var frameRate: Int
    /// Longest edge in pixels. A full-resolution GIF of a Retina screen is enormous and
    /// nobody wants it.
    public var maximumWidth: Int
    /// Loop forever, which is what a screen-recording GIF is for.
    public var loops: Bool

    public init(frameRate: Int = 15, maximumWidth: Int = 800, loops: Bool = true) {
        self.frameRate = min(max(frameRate, 1), 50)
        self.maximumWidth = max(maximumWidth, 80)
        self.loops = loops
    }

    /// Frame delay in hundredths of a second, which is the unit GIF actually stores.
    var frameDelay: Double {
        (100.0 / Double(frameRate)).rounded() / 100.0
    }
}

public enum GIFError: Error, Equatable, Sendable {
    case noVideoTrack
    case couldNotCreateDestination
    case encodingFailed
}

/// Turns a recording into a GIF (docs/03 §1.8).
///
/// **Why not gifski.** gifski produces the best-looking GIFs available and is AGPL.
/// Shipping it as a bundled CLI subprocess is the usual isolation argument, but it is a
/// contested one, and Kadr's whole pitch includes being MIT with no licensing landmines
/// (PRD §9, §11 question 2). So this uses ImageIO, which every Mac already has: it costs
/// some quality against gifski and nothing against the alternatives, and it keeps the
/// licence story simple enough to explain in a sentence.
///
/// Runs in the helper process, never the agent — a GIF encode holds every frame it is
/// working on, and that is exactly the memory the agent must not be spending (docs/04 §1).
public protocol GIFEncoding: Sendable {
    func encode(movieAt url: URL, to destination: URL, options: GIFOptions) async throws -> URL
    func estimatedSize(ofMovieAt url: URL, options: GIFOptions) async throws -> Int
}

public struct ImageIOGIFEncoder: GIFEncoding {
    private let logger = KadrLog.logger(.recording)

    public init() {}

    public func encode(movieAt url: URL, to destination: URL, options: GIFOptions) async throws -> URL {
        let asset = AVURLAsset(url: url)
        // A file that is not a movie fails inside AVFoundation with its own error; the
        // caller only needs to know there was nothing to encode.
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await CMTimeGetSeconds(asset.load(.duration))
        else {
            throw GIFError.noVideoTrack
        }
        let times = frameTimes(duration: duration, frameRate: options.frameRate)
        guard !times.isEmpty else { throw GIFError.encodingFailed }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Sampling has to be exact: a tolerant generator snaps to keyframes and the GIF
        // ends up stuttering on long static stretches.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = try await maximumSize(for: track, limit: options.maximumWidth)

        try? FileManager.default.removeItem(at: destination)
        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.gif.identifier as CFString,
            times.count,
            nil
        ) else {
            throw GIFError.couldNotCreateDestination
        }

        CGImageDestinationSetProperties(output, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: options.loops ? 0 : 1
            ]
        ] as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: options.frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: options.frameDelay
            ]
        ] as CFDictionary

        var written = 0
        for time in times {
            // One frame in memory at a time: the whole point of streaming into the
            // destination rather than collecting frames first.
            guard let image = try? await generator.image(at: time).image else { continue }
            CGImageDestinationAddImage(output, image, frameProperties)
            written += 1
        }

        guard written > 0, CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: destination)
            throw GIFError.encodingFailed
        }

        let bytes = Self.fileSize(of: destination)
        logger.info("Encoded \(written, privacy: .public) frames, \(bytes, privacy: .public) bytes")
        return destination
    }

    /// A size estimate to show before committing to an export (docs/03 §1.8).
    ///
    /// Encodes a handful of evenly spread frames and multiplies. Rough by construction —
    /// GIF size depends on how much changes between frames — but it is the difference
    /// between "about 8 MB" and finding out after a minute of encoding.
    public func estimatedSize(ofMovieAt url: URL, options: GIFOptions) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await CMTimeGetSeconds(asset.load(.duration))
        else {
            throw GIFError.noVideoTrack
        }
        let totalFrames = max(1, frameTimes(duration: duration, frameRate: options.frameRate).count)

        let sampleCount = min(6, totalFrames)
        let sampleTimes = (0 ..< sampleCount).map { index in
            CMTime(seconds: duration * Double(index) / Double(max(1, sampleCount)), preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = try await maximumSize(for: track, limit: options.maximumWidth)

        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-gif-estimate-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: probe) }

        guard let output = CGImageDestinationCreateWithURL(
            probe as CFURL,
            UTType.gif.identifier as CFString,
            sampleCount,
            nil
        ) else {
            throw GIFError.couldNotCreateDestination
        }

        var sampled = 0
        for time in sampleTimes {
            guard let image = try? await generator.image(at: time).image else { continue }
            CGImageDestinationAddImage(output, image, nil)
            sampled += 1
        }
        guard sampled > 0, CGImageDestinationFinalize(output) else { throw GIFError.encodingFailed }

        let sampleBytes = Self.fileSize(of: probe)
        guard sampleBytes > 0 else { throw GIFError.encodingFailed }
        return sampleBytes / max(1, sampled) * totalFrames
    }

    // MARK: - Geometry

    private static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func frameTimes(duration: Double, frameRate: Int) -> [CMTime] {
        guard duration > 0 else { return [] }
        let step = 1.0 / Double(frameRate)
        return stride(from: 0.0, to: duration, by: step).map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }
    }

    private func maximumSize(for track: AVAssetTrack, limit: Int) async throws -> CGSize {
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = natural.applying(transform)
        let width = abs(size.width)
        let height = abs(size.height)
        guard width > CGFloat(limit) else { return CGSize(width: width, height: height) }

        let scale = CGFloat(limit) / width
        return CGSize(width: CGFloat(limit), height: (height * scale).rounded())
    }
}
