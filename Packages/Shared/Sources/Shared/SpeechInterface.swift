import Foundation

// The wire contract for speech in the helper (docs/13 T1.1).
//
// Same reason as `VisionInterface`: the agent and the editor must name the types they
// send, and neither may link VisionServices — that is where Speech.framework actually
// loads. JSON on the wire, `@objc` on the methods, because NSXPC is still that.

/// Which stream a word came from, when the recording kept them apart.
public enum SpeechTrackKind: String, Codable, Sendable, Hashable {
    /// The user's microphone.
    case microphone
    /// System audio (the app being recorded).
    case system
    /// One mixed stream, when the file only had one audio track.
    case mixed
}

/// Which audio to transcribe.
public enum SpeechTrackSelection: String, Codable, Sendable, Hashable {
    /// Microphone when the file has one, otherwise system audio.
    case preferred
    /// Each track separately, labelled (docs/13 T2.4).
    case all
}

/// Whether a language can be transcribed, and whether it can be yet.
public enum SpeechModelStatus: String, Codable, Sendable, Hashable {
    case unsupported
    case available
    case downloading
    case installed
    /// macOS 14/15: no SpeechAnalyzer catalogue; `SFSpeechRecognizer` uses what Dictation
    /// already has.
    case notApplicable
}

/// What to transcribe.
public struct SpeechTranscriptionRequest: Codable, Sendable, Hashable {
    public var mediaPath: String
    public var localeIdentifier: String
    public var tracks: SpeechTrackSelection
    /// Seconds to wait before giving up. Zero means the helper picks a bound from duration.
    public var timeoutSeconds: Double

    public init(
        mediaPath: String,
        localeIdentifier: String,
        tracks: SpeechTrackSelection = .preferred,
        timeoutSeconds: Double = 0
    ) {
        self.mediaPath = mediaPath
        self.localeIdentifier = localeIdentifier
        self.tracks = tracks
        self.timeoutSeconds = max(timeoutSeconds, 0)
    }
}

/// One recognised word on the wire.
public struct SpeechWordDTO: Codable, Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var track: SpeechTrackKind

    public init(text: String, start: TimeInterval, end: TimeInterval, track: SpeechTrackKind) {
        self.text = text
        self.start = start
        self.end = max(end, start)
        self.track = track
    }
}

/// What the helper sends back from a transcription.
public struct SpeechTranscriptDTO: Codable, Sendable, Hashable {
    public var words: [SpeechWordDTO]
    public var audioContentHash: String
    public var localeIdentifier: String
    public var engine: String

    public init(
        words: [SpeechWordDTO],
        audioContentHash: String,
        localeIdentifier: String,
        engine: String
    ) {
        self.words = words
        self.audioContentHash = audioContentHash
        self.localeIdentifier = localeIdentifier
        self.engine = engine
    }
}

public struct SpeechStatusRequest: Codable, Sendable, Hashable {
    public var localeIdentifier: String

    public init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }
}

public struct SpeechStatusResponse: Codable, Sendable, Hashable {
    public var status: SpeechModelStatus
    public var supportedLocales: [String]
    public var resolvedLocale: String
    /// Set on macOS 14/15 when on-device recognition is missing, so the UI can point at
    /// System Settings ▸ Keyboard ▸ Dictation (docs/13 T-H5).
    public var dictationSettingsNeeded: Bool

    public init(
        status: SpeechModelStatus,
        supportedLocales: [String] = [],
        resolvedLocale: String,
        dictationSettingsNeeded: Bool = false
    ) {
        self.status = status
        self.supportedLocales = supportedLocales
        self.resolvedLocale = resolvedLocale
        self.dictationSettingsNeeded = dictationSettingsNeeded
    }
}

public struct SpeechInstallRequest: Codable, Sendable, Hashable {
    public var localeIdentifier: String

    public init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }
}

public struct SpeechLiveStartRequest: Codable, Sendable, Hashable {
    public var localeIdentifier: String
    public var sampleRate: Double

    public init(localeIdentifier: String, sampleRate: Double = 16000) {
        self.localeIdentifier = localeIdentifier
        self.sampleRate = sampleRate
    }
}

public struct SpeechHypothesisDTO: Codable, Sendable, Hashable {
    public var words: [String]
    public var isFinal: Bool

    public init(words: [String], isFinal: Bool) {
        self.words = words
        self.isFinal = isFinal
    }
}

/// Progress and live hypotheses, called *on* the client from the helper.
///
/// Bidirectional XPC: the helper's connection exports `VisionServiceProtocol` and the
/// client's connection exports this. Progress during a multi-minute transcription has
/// nowhere else to go — a single reply cannot move a bar.
@objc
public protocol SpeechClientProtocol: Sendable {
    func speechDidProgress(_ fraction: Double)
    func speechDidHypothesize(_ data: Data)
}

/// Opens System Settings to Keyboard ▸ Dictation, so a user on macOS 14/15 can fetch the
/// on-device model the legacy recogniser needs (docs/13 T-H5).
public enum SpeechDictationSettings {
    public static let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation")
}
