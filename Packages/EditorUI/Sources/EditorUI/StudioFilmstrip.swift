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

    static func tileCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width / tileWidth).rounded(.down)))
    }

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
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        var frames: [CGImage] = []
        frames.reserveCapacity(times.count)
        for time in times {
            if Task.isCancelled {
                return frames
            }
            let requested = CMTime(seconds: max(time, 0), preferredTimescale: 600)
            if let image = try? await generator.image(at: requested).image {
                frames.append(image)
            }
        }
        return frames
    }
}
