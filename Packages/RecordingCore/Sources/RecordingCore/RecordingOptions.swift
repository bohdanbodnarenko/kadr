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

    /// The preset closest to a requested rate.
    ///
    /// Automation may ask for `--fps 45` (docs/03 §8.4); the encoder has three presets,
    /// and recording at the nearest one is a better answer than refusing to record.
    public static func nearest(to rate: Int) -> RecordingFrameRate {
        allCases.min { abs($0.rawValue - rate) < abs($1.rawValue - rate) } ?? .sixty
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
    /// Keep the display's HDR range (macOS 15+, docs/04 §4.3, docs/06 M25).
    public var dynamicRange: DynamicRange

    public init(
        frameRate: RecordingFrameRate = .sixty,
        codec: RecordingCodec = .hevc,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = false,
        showsCursor: Bool = true,
        excludesOwnAudio: Bool = true,
        dynamicRange: DynamicRange = .standard
    ) {
        self.frameRate = frameRate
        self.codec = codec
        self.capturesSystemAudio = capturesSystemAudio
        // Resolved here, so a writer never creates a track nothing can feed.
        self.capturesMicrophone = capturesMicrophone && Self.microphoneIsAvailable
        self.showsCursor = showsCursor
        self.excludesOwnAudio = excludesOwnAudio
        // Resolved here rather than at the call site, so a recording started on macOS 14
        // with the setting on records standard rather than failing.
        self.dynamicRange = dynamicRange.resolved
    }

    /// HDR needs a codec that can carry ten bits; H.264 as Kadr configures it cannot.
    public var recordsHDR: Bool {
        dynamicRange.isHigh && codec == .hevc
    }

    /// Whether this system can record the microphone at all.
    ///
    /// ScreenCaptureKit gained microphone capture in macOS 15. Kadr ships to 14, and a
    /// toggle that silently records nothing is worse than one that is honestly
    /// unavailable — so the UI hides it below that (docs/07 H2).
    public static var microphoneIsAvailable: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    /// Whether this recording will actually carry a microphone track.
    public var recordsMicrophone: Bool {
        capturesMicrophone && Self.microphoneIsAvailable
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
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate(forPixelWidth: pixelWidth, height: pixelHeight),
            // Two seconds between keyframes: seeking stays responsive without paying
            // for a keyframe on every static screen.
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoExpectedSourceFrameRateKey: frameRate.rawValue
        ]
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight
        ]

        if recordsHDR {
            // Main10 plus the HLG tag set: HLG rather than PQ because an HLG file still
            // looks right on an SDR display, and a screen recording is shared far more
            // often than it is graded (docs/04 §4.3).
            compression[AVVideoProfileLevelKey] = "HEVC_Main10_AutoLevel"
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        }

        settings[AVVideoCompressionPropertiesKey] = compression
        return settings
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
    /// Asked for, and not yet running (docs/10 R0.3).
    ///
    /// Starting a capture is several hundred milliseconds of asking ScreenCaptureKit for
    /// permission, content and a stream. Without a state for that window the app is idle by
    /// its own account while a recording is being set up, so a second trigger starts a
    /// second one — and the second one's failure path tears down the first.
    case starting
    case recording
    case paused
    case finishing

    /// Whether a recording exists, including one still being set up.
    ///
    /// The question every caller actually means. `== .recording` is the question almost
    /// nobody means, and answering the wrong one is what let two recordings overlap.
    public var isActive: Bool {
        self != .idle
    }
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
    /// The recording was cancelled while it was still being set up (docs/11 S0.3).
    ///
    /// Not a failure the user needs telling about — they are the one who cancelled — but
    /// the in-flight `start` has to be told something, because the alternative is that it
    /// resumes and announces a recording whose session directory has already been deleted.
    case cancelledDuringStart
    /// The segments were captured but could not be joined — a full disk, an unwritable
    /// destination. Carries where the (individually playable) segments are, because
    /// losing footage to a failed join is not an acceptable outcome (docs/09 U0.3).
    case stitchFailed(reason: String, segmentDirectory: String?)
}

extension RecordingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "A recording is already running."
        case .notRecording:
            "Nothing is recording."
        case .targetUnavailable:
            "That screen or window is no longer available to record."
        case let .couldNotCreateWriter(reason), let .writingFailed(reason):
            reason
        case .noFramesCaptured:
            "The recording captured no frames."
        case .cancelledDuringStart:
            "The recording was cancelled before it began."
        case let .stitchFailed(reason, directory):
            if let directory {
                "Kadr could not join the recording (\(reason)). The parts are still in \(directory)."
            } else {
                "Kadr could not join the recording: \(reason)"
            }
        }
    }
}
