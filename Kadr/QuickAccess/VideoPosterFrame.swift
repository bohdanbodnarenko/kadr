import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Shared

/// A still from a recording, for the overlay card (docs/03 §1.8, §2).
///
/// Cards show a picture, and a recording's picture is a frame from it. Taken a moment in
/// rather than at zero, because the first frame of a screen recording is often the
/// selection overlay fading out.
enum VideoPosterFrame {
    static func posterFrame(of url: URL, maxPixelSize: Int? = nil) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxPixelSize {
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        }

        let duration = await (try? asset.load(.duration)) ?? .zero
        let time = CMTimeGetSeconds(duration) > 1
            ? CMTime(seconds: 0.5, preferredTimescale: 600)
            : CMTime.zero

        return try? await generator.image(at: time).image
    }

    /// A still at the recording's native size, for OCR (CleanShot §3.7).
    static func still(of url: URL) async -> CGImage? {
        await posterFrame(of: url, maxPixelSize: nil)
    }

    /// The recording's pixel size, read from its video track.
    ///
    /// The transform matters: a track can be stored rotated, and a card sized from the
    /// raw dimensions would be the wrong way round.
    static func pixelSize(of url: URL) async -> PixelSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }

        let size = natural.applying(transform)
        return PixelSize(width: Int(abs(size.width)), height: Int(abs(size.height)))
    }

    /// How long the movie is, or nil when it cannot be opened.
    static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0.1 else { return nil }
        return seconds
    }
}
