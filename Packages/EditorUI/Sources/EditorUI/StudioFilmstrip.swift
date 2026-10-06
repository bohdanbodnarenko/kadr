import AVFoundation
import CoreGraphics
import Foundation

/// Sample times and frames for the studio timeline filmstrip.
enum StudioFilmstrip {
    /// How wide each thumbnail tile aims to be, in points.
    static let tileWidth: CGFloat = 36

    /// Midpoints of `count` equal slices of `[start, start + duration)`.
    ///
    /// Midpoints rather than the left edge, so a tile shows what that stretch looks like
    /// rather than always the frame that begins it.
    static func sampleTimes(start: TimeInterval, duration: TimeInterval, count: Int) -> [TimeInterval] {
        let count = max(count, 0)
        guard duration > 0, count > 0 else {
            return []
        }
        if count == 1 {
            return [start + duration / 2]
        }
        return (0 ..< count).map { index in
            start + duration * (Double(index) + 0.5) / Double(count)
        }
    }

    private static let timescale: CMTimeScale = 600

    /// How many tiles a lane of `width` points draws, never more than `maximumTiles`.
    ///
    /// A 30-minute recording at full timeline zoom is a lane hundreds of thousands of
    /// points wide, and one tile per 36 points was thousands of views laid out and decoded
    /// eagerly (docs/18 STU-15). Past the cap each tile stretches; the picture is a guide to
    /// where you are, not a frame-accurate strip.
    static func tileCount(forWidth width: CGFloat) -> Int {
        guard width.isFinite else { return 1 }
        return min(max(1, Int((width / tileWidth).rounded(.down))), maximumTiles)
    }

    /// The most tiles one clip's lane draws.
    static let maximumTiles = 240

    /// Decodes the frames at `times`. A missing file or a cancelled task yields `[]`
    /// rather than throwing — the lane is still a clip without a picture in it.
    static func images(
        from url: URL,
        times: [TimeInterval],
        maximumSize: CGSize = CGSize(width: 80, height: 80)
    ) async -> [CGImage] {
        guard FileManager.default.fileExists(atPath: url.path), !times.isEmpty else {
            return []
        }
        let generator = makeGenerator(for: url, maximumSize: maximumSize)
        return await images(from: generator, times: times).compactMap(\.self)
    }

    /// A generator configured the way the filmstrip wants its tiles.
    static func makeGenerator(for url: URL, maximumSize: CGSize) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        return generator
    }

    /// Decodes `times` as one batch, aligned with `times`: nil where a frame failed or the
    /// task was cancelled before it arrived.
    ///
    /// One `images(for:)` request rather than one `image(at:)` per time, so AVFoundation can
    /// order the work and decode forward through the movie instead of seeking per tile.
    static func images(from generator: AVAssetImageGenerator, times: [TimeInterval]) async -> [CGImage?] {
        guard !times.isEmpty else { return [] }
        // Keyed by the tick count at a fixed timescale: the result echoes the requested
        // time exactly, and duplicates are asked for once and fanned out.
        var slots: [Int64: [Int]] = [:]
        var unique: [CMTime] = []
        for (index, time) in times.enumerated() {
            let requested = CMTime(seconds: max(time, 0), preferredTimescale: timescale)
            if slots[requested.value] == nil {
                unique.append(requested)
            }
            slots[requested.value, default: []].append(index)
        }
        var frames = [CGImage?](repeating: nil, count: times.count)
        for await result in generator.images(for: unique) {
            if Task.isCancelled {
                break
            }
            guard case let .success(requestedTime, image, _) = result else { continue }
            for index in slots[requestedTime.convertScale(timescale, method: .default).value] ?? [] {
                frames[index] = image
            }
        }
        return frames
    }
}
