import AVFoundation
import CoreGraphics
import Foundation
import Shared

/// Video codecs Kadr records with (docs/03 §1.8).
public enum RecordingCodec: String, CaseIterable, Sendable {
    /// Hardware HEVC: roughly half the size of H.264 at the same quality, and every Mac
    /// that runs macOS 14 encodes it in hardware.
    case hevc
    /// H.264, for handing a file to something old.
    case h264

    public var title: String {
        switch self {
        case .hevc: "HEVC (smaller)"
        case .h264: "H.264 (most compatible)"
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        }
    }
}

/// Frame rates the UI offers (docs/03 §1.8).
public enum RecordingFrameRate: Int, CaseIterable, Sendable {
    case twentyFour = 24
    case thirty = 30
    case sixty = 60

    public var title: String {
        "\(rawValue) fps"
    }
}

/// What a recording captures.
public struct RecordingOptions: Sendable, Hashable {
    public var frameRate: RecordingFrameRate
    public var codec: RecordingCodec
    /// System audio, through ScreenCaptureKit — no audio driver to install (docs/03 §1.8).
    public var capturesSystemAudio: Bool
    public var capturesMicrophone: Bool
    public var showsCursor: Bool
    /// Kadr's own sound never belongs in a recording of the user's screen.
    public var excludesOwnAudio: Bool

    public init(
        frameRate: RecordingFrameRate = .sixty,
        codec: RecordingCodec = .hevc,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = false,
        showsCursor: Bool = true,
        excludesOwnAudio: Bool = true
    ) {
        self.frameRate = frameRate
        self.codec = codec
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.showsCursor = showsCursor
        self.excludesOwnAudio = excludesOwnAudio
    }

    /// A bit rate that holds up for screen content at this size and frame rate.
    ///
    /// Screen recordings are mostly static with sudden large changes — scrolling, window
    /// switches — which is the opposite of camera footage. The multiplier is deliberately
    /// generous: text that turns to mush on a scroll is the failure people notice.
    func bitRate(forPixelWidth width: Int, height: Int) -> Int {
        let pixels = Double(width * height)
        let perFrame = pixels * (codec == .hevc ? 0.09 : 0.15)
        return Int(perFrame * Double(frameRate.rawValue))
    }

    /// AVFoundation settings for the video track.
    func videoSettings(pixelWidth: Int, pixelHeight: Int) -> [String: Any] {
        [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate(forPixelWidth: pixelWidth, height: pixelHeight),
                // Two seconds between keyframes: seeking stays responsive without paying
                // for a keyframe on every static screen.
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoExpectedSourceFrameRateKey: frameRate.rawValue
            ]
        ]
    }

    /// AVFoundation settings for an audio track.
    func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
    }
}

/// What a recording is pointed at (docs/03 §1.8: the same selection grammar as stills).
public enum RecordingTarget: Sendable, Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(DisplayRect, display: CGDirectDisplayID)
}

/// Where a recording is in its life.
public enum RecordingState: Sendable, Equatable {
    case idle
    case recording
    case paused
    case finishing
}

/// A finished recording.
public struct RecordingResult: Sendable, Hashable {
    public let fileURL: URL
    public let duration: TimeInterval
    public let pixelSize: PixelSize
    public let options: RecordingOptions

    public init(fileURL: URL, duration: TimeInterval, pixelSize: PixelSize, options: RecordingOptions) {
        self.fileURL = fileURL
        self.duration = duration
        self.pixelSize = pixelSize
        self.options = options
    }
}

public enum RecordingError: Error, Equatable, Sendable {
    case alreadyRecording
    case notRecording
    case targetUnavailable
    case couldNotCreateWriter(String)
    case writingFailed(String)
    case noFramesCaptured
}
