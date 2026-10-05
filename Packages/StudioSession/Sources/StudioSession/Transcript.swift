import CryptoKit
import Foundation
import Shared

/// One recognised word, with when it was said (docs/09 U3.6, docs/13).
///
/// Word-level timings rather than sentences, because a filler word is removed by cutting
/// exactly around it — a sentence-level transcript can say "um" was in there somewhere and
/// nothing more.
public struct TranscriptWord: Sendable, Hashable, Codable, Identifiable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var track: SpeechTrackKind

    public init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        track: SpeechTrackKind = .mixed
    ) {
        self.text = text
        self.start = start
        self.end = max(end, start)
        self.track = track
    }

    public var duration: TimeInterval {
        end - start
    }

    public var id: String {
        "\(track.rawValue):\(start):\(end):\(text)"
    }

    /// The word with punctuation and case removed, for matching against the filler list.
    public var normalized: String {
        text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private enum CodingKeys: String, CodingKey {
        case text, start, end, track
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            text: container.decode(String.self, forKey: .text),
            start: container.decode(TimeInterval.self, forKey: .start),
            end: container.decode(TimeInterval.self, forKey: .end),
            track: container.decodeIfPresent(SpeechTrackKind.self, forKey: .track) ?? .mixed
        )
    }
}

/// What was said, and when (docs/09 U3.6).
public struct Transcript: Sendable, Hashable, Codable {
    public static let currentVersion = 1

    public var words: [TranscriptWord]
    /// SHA-256 of the media file this was produced from, so a re-record invalidates it.
    public var audioContentHash: String
    public var localeIdentifier: String
    public var engine: String
    public var version: Int

    public init(
        words: [TranscriptWord] = [],
        audioContentHash: String = "",
        localeIdentifier: String = "",
        engine: String = "",
        version: Int = Transcript.currentVersion
    ) {
        self.words = words.sorted { $0.start < $1.start }
        self.audioContentHash = audioContentHash
        self.localeIdentifier = localeIdentifier
        self.engine = engine
        self.version = version
    }

    public init(_ dto: SpeechTranscriptDTO) {
        self.init(
            words: dto.words.map {
                TranscriptWord(text: $0.text, start: $0.start, end: $0.end, track: $0.track)
            },
            audioContentHash: dto.audioContentHash,
            localeIdentifier: dto.localeIdentifier,
            engine: dto.engine
        )
    }

    public var dto: SpeechTranscriptDTO {
        SpeechTranscriptDTO(
            words: words.map {
                SpeechWordDTO(text: $0.text, start: $0.start, end: $0.end, track: $0.track)
            },
            audioContentHash: audioContentHash,
            localeIdentifier: localeIdentifier,
            engine: engine
        )
    }

    public var isEmpty: Bool {
        words.isEmpty
    }

    public var duration: TimeInterval {
        words.last?.end ?? 0
    }

    public var text: String {
        words.map(\.text).joined(separator: " ")
    }

    /// Words from one stream, for the two-track view (docs/13 T2.4).
    public func words(on track: SpeechTrackKind) -> [TranscriptWord] {
        words.filter { $0.track == track }
    }

    /// On-device `SFSpeechRecognizer` is known to return `timestamp == 0` for every
    /// segment in some configurations; then every word sits at 0 and a tidy would collapse
    /// the timeline (docs/13 T-C3).
    public func timingsLookCollapsed(relativeTo duration: TimeInterval) -> Bool {
        guard duration > 2, !words.isEmpty else { return false }
        return self.duration < 0.5
    }

    /// The transcript's span should bear some relation to the recording (docs/13 T0.3).
    public func spanLooksPlausible(relativeTo duration: TimeInterval) -> Bool {
        guard duration > 1, !words.isEmpty else { return true }
        if timingsLookCollapsed(relativeTo: duration) {
            return false
        }
        return self.duration <= duration * 1.15
    }

    private enum CodingKeys: String, CodingKey {
        case words, audioContentHash, localeIdentifier, engine, version
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            words: container.decodeIfPresent([TranscriptWord].self, forKey: .words) ?? [],
            audioContentHash: container.decodeIfPresent(String.self, forKey: .audioContentHash) ?? "",
            localeIdentifier: container.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? "",
            engine: container.decodeIfPresent(String.self, forKey: .engine) ?? "",
            version: container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        )
    }
}

/// Options a transcriber accepts. Engines that do not have a field ignore it
/// (`scoped(to:)` is the choke point, docs/13 T1.2).
public struct TranscriptionOptions: Sendable, Hashable {
    public var localeIdentifier: String
    public var tracks: SpeechTrackSelection
    public var timeout: TimeInterval

    public init(
        localeIdentifier: String = Locale.current.identifier,
        tracks: SpeechTrackSelection = .preferred,
        timeout: TimeInterval = 0
    ) {
        self.localeIdentifier = localeIdentifier
        self.tracks = tracks
        self.timeout = max(timeout, 0)
    }

    /// How long to wait for a recording of `duration` seconds before calling the helper
    /// stuck: three times real time, never under 30 minutes (docs/18 STU-9). A flat
    /// 30 minutes failed every recording longer than about that.
    public static func timeout(forDuration duration: TimeInterval) -> TimeInterval {
        max(30 * 60, duration * 3)
    }

    public func scoped(to engine: SpeechEngineKind) -> TranscriptionOptions {
        switch engine {
        case .appleAnalyzer, .appleLegacy:
            self
        }
    }
}

public enum SpeechEngineKind: String, Sendable, Hashable {
    case appleAnalyzer
    case appleLegacy
}

/// Turning a recording's audio into words. Implementations live in the helper; this
/// protocol is the injection point the studio tests through (docs/13 T0.2).
public protocol Transcribing: Sendable {
    func transcribe(
        audioAt url: URL,
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript

    func requestAuthorization() async -> Bool
}

public extension Transcribing {
    func requestAuthorization() async -> Bool {
        true
    }
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case notAuthorized
    case unavailableOnDevice
    case noAudioTrack
    case collapsedTimestamps
    case failed(String)
}

/// SHA-256 of a media file, so a persisted transcript invalidates when the audio changes.
///
/// Hashing is linear in the size of the footage — seconds for a multi-gigabyte recording —
/// so callers run it off the main actor, and `SessionDocument.audioContentHash()` skips it
/// entirely when the file is provably the one that was hashed last time.
public enum AudioContentHash {
    /// How much is read per step. Large enough that the syscall count stays small on a
    /// multi-gigabyte file, small enough that cancellation is noticed within a few
    /// milliseconds and the resident footprint stays flat.
    static let chunkSize = 4 * 1024 * 1024

    /// - Throws: `CancellationError` when the calling task is cancelled between chunks, so
    ///   closing a studio mid-hash stops reading the footage rather than finishing the pass.
    public static func hash(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What a file *is* on disk, cheaply: enough to say "this is the same bytes as last time"
/// without reading them (docs/13 T2.3).
///
/// Size, modification time and the file's inode on its volume. A re-recorded or replaced
/// `screen.mov` changes at least one of those — an atomic replace gets a new inode even when
/// the size and timestamp happen to agree — so a match is a safe reason to reuse a hash, and
/// anything else falls back to hashing the footage again.
public struct AudioFileIdentity: Codable, Sendable, Hashable {
    public var byteCount: Int64
    /// Seconds since the reference date. A `TimeInterval` rather than a `Date` so the JSON
    /// round trip is a plain number and cannot pick up a formatting strategy.
    public var modified: TimeInterval
    public var fileNumber: UInt64
    public var volumeNumber: Int64

    public init(byteCount: Int64, modified: TimeInterval, fileNumber: UInt64, volumeNumber: Int64) {
        self.byteCount = byteCount
        self.modified = modified
        self.fileNumber = fileNumber
        self.volumeNumber = volumeNumber
    }

    /// The identity of the file at `url`, or nil if it cannot be read.
    public init?(fileAt url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        self.init(
            byteCount: size,
            modified: modified.timeIntervalSinceReferenceDate,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            volumeNumber: (attributes[.systemNumber] as? NSNumber)?.int64Value ?? 0
        )
    }
}

/// A content hash remembered against the identity of the file it was computed from.
///
/// Written beside the transcript so reopening a studio does not re-read the whole
/// recording to prove what the fingerprint already proves.
public struct AudioContentHashCache: Codable, Sendable, Hashable {
    public var identity: AudioFileIdentity
    public var hash: String

    public init(identity: AudioFileIdentity, hash: String) {
        self.identity = identity
        self.hash = hash
    }
}

/// Resolves a language choice against what an engine actually supports (docs/13 T1.6).
public enum SpeechLanguage {
    /// Empty means "this Mac's current locale".
    public static func currentIdentifier(_ stored: String) -> String {
        stored.isEmpty ? Locale.current.identifier : stored
    }

    public static func resolved(_ preferred: String, supported: [String]) -> String {
        let wanted = currentIdentifier(preferred)
        if supported.isEmpty {
            return wanted
        }
        if supported.contains(wanted) {
            return wanted
        }
        let wantedLanguage = Locale(identifier: wanted).language.languageCode?.identifier
        if let wantedLanguage {
            if let match = supported.first(where: {
                Locale(identifier: $0).language.languageCode?.identifier == wantedLanguage
            }) {
                return match
            }
        }
        return supported.first ?? wanted
    }
}
