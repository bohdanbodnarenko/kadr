import AVFoundation
import CoreGraphics

/// How the export is encoded (docs/09 U3.3).
extension StudioRenderer {
    /// What the video encoder is asked for (docs/09 U3.3).
    ///
    /// A quality target replaces the bit-rate target rather than joining it: VideoToolbox
    /// given both, or a data-rate cap on top of a quality, produced *larger* files in
    /// testing. The keyframe interval widens with it, because the still stretches a
    /// quality target makes cheap are exactly the ones a keyframe every two seconds
    /// re-encodes in full. H.264 always asks for the High profile, which compresses better
    /// than the encoder's default and plays on anything made this decade.
    static func compressionProperties(for options: Options, size: CGSize) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: options.frameRate
        ]
        if let quality = options.targetQuality {
            compression[AVVideoQualityKey] = quality
            compression[AVVideoMaxKeyFrameIntervalKey] = options.frameRate * 4
        } else {
            compression[AVVideoMaxKeyFrameIntervalKey] = options.frameRate * 2
            compression[AVVideoAverageBitRateKey] = Int(
                Double(options.bitRate ?? bitRate(for: size, frameRate: options.frameRate))
                    * max(options.bitRateMultiplier, 0.05)
            )
        }
        if options.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return compression
    }

    /// A bit rate for a size and a frame rate.
    ///
    /// Roughly 0.1 bits per pixel per frame, which is where HEVC stops showing blocking on
    /// screen content — text and flat colour, which compress well but show artefacts
    /// mercilessly. Screen recordings are not film and a film-derived table under-serves
    /// them badly.
    public static func bitRate(for size: CGSize, frameRate: Int) -> Int {
        let pixels = Double(size.width * size.height)
        let estimate = pixels * Double(max(frameRate, 1)) * 0.1
        return Int(min(max(estimate, 1_500_000), 60_000_000))
    }
}
