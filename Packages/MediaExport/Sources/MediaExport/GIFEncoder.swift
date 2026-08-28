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
    /// Roughly how much memory the encode may hold at once.
    ///
    /// ImageIO keeps every frame added to a GIF destination until `finalize`, so this is
    /// the only lever there is: exceed it and the encode is planned down rather than run
    /// (docs/07 M10, and see `GIFPlan`).
    public var peakMemoryBudget: Int

    public init(
        frameRate: Int = 15,
        maximumWidth: Int = 800,
        loops: Bool = true,
        peakMemoryBudget: Int = 400 * 1024 * 1024
    ) {
        self.frameRate = min(max(frameRate, 1), 50)
        self.maximumWidth = max(maximumWidth, 80)
        self.loops = loops
        self.peakMemoryBudget = max(peakMemoryBudget, 16 * 1024 * 1024)
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
    /// What an encode would actually do, so the user can be asked about the real thing.
    func plan(forMovieAt url: URL, options: GIFOptions) async throws -> GIFPlan
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
        // Planned before a single frame is decoded: ImageIO holds them all until the
        // destination is finalised, so the size of the job has to be decided up front
        // (docs/07 M10).
        let plan = try await GIFPlan.fitting(
            sourceSeconds: duration,
            frameSize: displaySize(of: track),
            options: options
        )
        let times = frameTimes(duration: plan.encodedSeconds, frameRate: plan.frameRate)
        guard !times.isEmpty else { throw GIFError.encodingFailed }
        if plan.isReduced {
            logger.info(
                """
                GIF planned down to \(plan.frameRate, privacy: .public) fps, \
                \(plan.maximumWidth, privacy: .public) px, \
                \(plan.encodedSeconds, privacy: .public) s
                """
            )
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Sampling has to be exact: a tolerant generator snaps to keyframes and the GIF
        // ends up stuttering on long static stretches.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = try await maximumSize(for: track, limit: plan.maximumWidth)

        let output = try makeDestination(
            at: destination,
            frameCount: times.count,
            loops: options.loops
        )
        let frameProperties = Self.frameProperties(frameRate: plan.frameRate)

        var written = 0
        for time in times {
            // ImageIO keeps every frame until `finalize`, so how many there are is the
            // memory question — `plan` is what answers it.
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

    /// Creates the GIF destination, replacing whatever was there.
    private func makeDestination(at url: URL, frameCount: Int, loops: Bool) throws -> CGImageDestination {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw GIFError.couldNotCreateDestination
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loops ? 0 : 1
            ]
        ] as CFDictionary)
        return destination
    }

    /// The per-frame delay, in the hundredths of a second GIF actually stores.
    private static func frameProperties(frameRate: Int) -> CFDictionary {
        let delay = (100.0 / Double(frameRate)).rounded() / 100.0
        return [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ] as CFDictionary
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
        let plan = try await GIFPlan.fitting(
            sourceSeconds: duration,
            frameSize: displaySize(of: track),
            options: options
        )
        let totalFrames = max(1, plan.frameCount)

        let sampleCount = min(6, totalFrames)
        let sampleTimes = (0 ..< sampleCount).map { index in
            CMTime(
                seconds: plan.encodedSeconds * Double(index) / Double(max(1, sampleCount)),
                preferredTimescale: 600
            )
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = try await maximumSize(for: track, limit: plan.maximumWidth)

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

    /// The plan an encode of this movie would follow.
    public func plan(forMovieAt url: URL, options: GIFOptions) async throws -> GIFPlan {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await CMTimeGetSeconds(asset.load(.duration))
        else {
            throw GIFError.noVideoTrack
        }
        return try await GIFPlan.fitting(
            sourceSeconds: duration,
            frameSize: displaySize(of: track),
            options: options
        )
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

    /// The track's size as it is meant to be seen, with its transform applied.
    private func displaySize(of track: AVAssetTrack) async throws -> CGSize {
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = natural.applying(transform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    private func maximumSize(for track: AVAssetTrack, limit: Int) async throws -> CGSize {
        let size = try await displaySize(of: track)
        let width = size.width
        let height = size.height
        guard width > CGFloat(limit) else { return CGSize(width: width, height: height) }

        let scale = CGFloat(limit) / width
        return CGSize(width: CGFloat(limit), height: (height * scale).rounded())
    }
}
