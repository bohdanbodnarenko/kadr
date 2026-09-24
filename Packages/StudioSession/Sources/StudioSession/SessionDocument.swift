import CryptoKit
import Foundation
import os
import Shared

/// What was being recorded (docs/09 U3.1).
public struct CaptureManifest: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    /// The recorded area's pixel size.
    public var pixelSize: CGSize
    /// Pixels per point, so the reconstruction draws a cursor the right size.
    public var scale: CGFloat
    public var frameRate: Int
    /// How long the recording is, in recording time.
    public var duration: TimeInterval
    /// Whether the pointer is baked into the footage.
    ///
    /// It should not be: reconstruction needs a clean plate, because a cursor already in
    /// the pixels cannot be smoothed, moved, or scaled with a zoom. Recorded so an older
    /// session with a baked cursor can be handled rather than double-drawn.
    public var hasBakedCursor: Bool
    /// Whether a camera stream was recorded alongside.
    public var hasCamera: Bool
    /// The notch strip at the top of the recorded display, in recorded pixels (docs/08 §2).
    ///
    /// Zero on a display without one. Captured at record time because it cannot be worked
    /// out afterwards: the answer belongs to a display that may not be attached by the time
    /// anybody opens the editor, and guessing a menu-bar height gets it wrong on exactly the
    /// Macs that have a notch — theirs is taller than everyone else's.
    public var topInset: CGFloat
    /// How far into the recording the camera's first frame landed (docs/10 R0.5).
    ///
    /// A capture session takes a moment to hand over its first frame — a third of a second
    /// on a built-in camera, well over a second on some external ones — and the screen is
    /// already recording. Without this the editor has no way to know, because the error is
    /// not visible in either file: both start at zero and one of them starts late. Measured
    /// at capture, when it is the only time it can be measured at all.
    public var cameraStartOffset: TimeInterval

    public init(
        version: Int = CaptureManifest.currentVersion,
        pixelSize: CGSize,
        scale: CGFloat = 2,
        frameRate: Int = 60,
        duration: TimeInterval = 0,
        hasBakedCursor: Bool = false,
        hasCamera: Bool = false,
        cameraStartOffset: TimeInterval = 0,
        topInset: CGFloat = 0
    ) {
        self.version = version
        self.pixelSize = pixelSize
        self.scale = scale
        self.frameRate = frameRate
        self.duration = duration
        self.hasBakedCursor = hasBakedCursor
        self.hasCamera = hasCamera
        self.cameraStartOffset = max(cameraStartOffset, 0)
        self.topInset = max(topInset, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case version, pixelSize, scale, frameRate, duration, hasBakedCursor, hasCamera, cameraStartOffset
        case topInset
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            pixelSize: container.decodeIfPresent(CGSize.self, forKey: .pixelSize) ?? .zero,
            scale: container.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 2,
            frameRate: container.decodeIfPresent(Int.self, forKey: .frameRate) ?? 60,
            duration: container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0,
            hasBakedCursor: container.decodeIfPresent(Bool.self, forKey: .hasBakedCursor) ?? false,
            hasCamera: container.decodeIfPresent(Bool.self, forKey: .hasCamera) ?? false,
            // Sessions recorded before the offset was measured decode as zero, which is
            // the old behaviour exactly: aligned at the start and out by however long the
            // camera took to wake up.
            cameraStartOffset: container.decodeIfPresent(TimeInterval.self, forKey: .cameraStartOffset) ?? 0,
            // Zero for a session recorded before this was captured, which is the honest
            // answer: nobody knows what that display's notch was, and offering to trim a
            // strip of unknown height would cut into the picture.
            topInset: container.decodeIfPresent(CGFloat.self, forKey: .topInset) ?? 0
        )
    }
}

/// Proof that a rendered file matches the edit that produced it (docs/09 U3.1).
///
/// Exporting a studio recording is minutes of work. Doing it again because the user pressed
/// the button twice is minutes wasted; *not* doing it again because the app assumed nothing
/// had changed is a wrong file shipped. A hash of the edit settles it: the same edit is the
/// same stamp, and any change at all is a different one.
public struct RenderStamp: Codable, Sendable, Hashable {
    /// A digest of the edit this render came from.
    public var editDigest: String
    /// Where the rendered file is.
    public var outputPath: String
    /// What it was rendered at, so a request for a different size is not mistaken for a
    /// cache hit.
    public var pixelSize: CGSize
    /// A digest of the export settings this file was encoded with. Optional so stamps
    /// written before the options popover existed still decode.
    public var settingsDigest: String?
    /// A digest of everything outside the edit that changes the pixels (docs/17 T-STU-1):
    /// the app build, the renderer's version, the transcript and the imported wallpaper
    /// and soundtrack. Optional so older stamps still decode — and a caller that asks
    /// for a match with inputs never matches a stamp without them.
    public var inputsDigest: String?

    public init(
        editDigest: String,
        outputPath: String,
        pixelSize: CGSize,
        settingsDigest: String? = nil,
        inputsDigest: String? = nil
    ) {
        self.editDigest = editDigest
        self.outputPath = outputPath
        self.pixelSize = pixelSize
        self.settingsDigest = settingsDigest
        self.inputsDigest = inputsDigest
    }

    /// Whether a cached render can be handed over instead of doing the work again.
    ///
    /// The file has to still be there: a stamp naming a file the user has since moved is a
    /// stamp for nothing. An empty digest is never a hit — two failed encodes used to
    /// collide into shipping the wrong file (docs/10 R3.5).
    ///
    /// When `inputsDigest` is given it has to be equal, and a stamp written before inputs
    /// were recorded is stale: it may predate a render fix, which is the whole point.
    public func matches(
        editDigest: String,
        pixelSize: CGSize,
        settingsDigest: String? = nil,
        inputsDigest: String? = nil
    ) -> Bool {
        guard !editDigest.isEmpty, !self.editDigest.isEmpty else { return false }
        if let stored = self.settingsDigest, stored != settingsDigest {
            return false
        }
        if let inputsDigest, self.inputsDigest != inputsDigest {
            return false
        }
        return self.editDigest == editDigest
            && self.pixelSize == pixelSize
            && FileManager.default.fileExists(atPath: outputPath)
    }

    /// The digest of an edit, or nil if it could not be encoded.
    ///
    /// Encoded with sorted keys so the same edit always hashes the same way — without that
    /// a dictionary's iteration order would make every second export a cache miss. Nil
    /// rather than empty: an empty string compared equal to another empty string, which is
    /// the exact "wrong file shipped" outcome this type exists to prevent.
    public static func digest(of value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reading and writing the parts of a session (docs/09 U3.1).
///
/// Every write is atomic. A sidecar half-written by a crash is worse than one that is
/// absent: absent is recoverable, half-written is a file that decodes into nonsense and
/// then gets rendered.
public struct SessionDocument: Sendable {
    private let logger = KadrLog.logger(.recording)
    public let session: RecordingSession

    public init(session: RecordingSession) {
        self.session = session
    }

    // MARK: - Writing

    public func write(_ telemetry: InputTelemetry) throws {
        try write(telemetry, to: session.inputURL)
    }

    public func write(_ manifest: CaptureManifest) throws {
        try write(manifest, to: session.captureURL)
    }

    public func write(_ stamp: RenderStamp) throws {
        try write(stamp, to: session.renderStampURL)
    }

    public func write(_ transcript: Transcript) throws {
        try write(transcript, to: session.transcriptURL)
    }

    /// Commits an edit, and clears the draft it came from.
    public func commit(_ edit: some Encodable) throws {
        try write(edit, to: session.editURL)
        try? FileManager.default.removeItem(at: session.draftEditURL)
    }

    /// Saves the edit in progress, leaving the committed one alone.
    public func writeDraft(_ edit: some Encodable) throws {
        try write(edit, to: session.draftEditURL)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    // MARK: - Reading

    public func telemetry() -> InputTelemetry? {
        read(InputTelemetry.self, from: session.inputURL)
    }

    public func manifest() -> CaptureManifest? {
        read(CaptureManifest.self, from: session.captureURL)
    }

    public func renderStamp() -> RenderStamp? {
        read(RenderStamp.self, from: session.renderStampURL)
    }

    /// The cached transcript, if it still matches this footage.
    public func transcript(matchingHash hash: String? = nil) -> Transcript? {
        guard let stored = read(Transcript.self, from: session.transcriptURL) else { return nil }
        if let hash, !stored.audioContentHash.isEmpty, stored.audioContentHash != hash {
            return nil
        }
        return stored
    }

    // MARK: - Transcript validation

    /// Where the footage's remembered content hash lives.
    ///
    /// Beside the transcript rather than inside it: the transcript is written by the
    /// transcriber and describes words, and this describes a file on disk. Losing it costs
    /// one re-hash and nothing else. Listed in `RecordingSession.allURLs`, so deleting or
    /// measuring a session accounts for it.
    public var audioHashCacheURL: URL {
        session.directory.appendingPathComponent("transcript.fingerprint.json")
    }

    public func audioHashCache() -> AudioContentHashCache? {
        read(AudioContentHashCache.self, from: audioHashCacheURL)
    }

    public func write(_ cache: AudioContentHashCache) throws {
        try write(cache, to: audioHashCacheURL)
    }

    /// The footage's content hash, reusing the remembered one when the file is unchanged.
    ///
    /// Blocking and linear in the footage on a miss — call it off the main actor. A file
    /// whose size, modification time or inode differ from the remembered ones is hashed
    /// again, so the invalidation is exactly as strict as hashing every time; only the
    /// cost of proving "nothing changed" goes away.
    ///
    /// - Throws: whatever reading the footage throws, including `CancellationError`.
    public func audioContentHash() throws -> String {
        let url = session.screenURL
        let before = AudioFileIdentity(fileAt: url)
        if let before, let cached = audioHashCache(), cached.identity == before, !cached.hash.isEmpty {
            return cached.hash
        }
        let hash = try AudioContentHash.hash(fileAt: url)
        // Only remembered if the file did not change underneath the read: a hash of a file
        // that was being written is a hash of neither version.
        if let before, AudioFileIdentity(fileAt: url) == before {
            do {
                try write(AudioContentHashCache(identity: before, hash: hash))
            } catch {
                logger.error("Could not remember the footage hash: \(error.localizedDescription, privacy: .public)")
            }
        }
        return hash
    }

    /// The persisted transcript, if it still describes this footage.
    ///
    /// The same rule as `transcript(matchingHash:)` with the footage's own hash: a transcript
    /// without a recorded hash is trusted, and a hash that cannot be computed does not
    /// discard one. Skips hashing entirely when there is no transcript to validate, which is
    /// every recording nobody has transcribed.
    ///
    /// - Throws: `CancellationError` if the calling task is cancelled mid-hash.
    public func transcriptMatchingFootage() throws -> Transcript? {
        guard let stored = read(Transcript.self, from: session.transcriptURL) else { return nil }
        guard !stored.audioContentHash.isEmpty else { return stored }
        let hash: String?
        do {
            hash = try audioContentHash()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            hash = nil
        }
        if let hash, stored.audioContentHash != hash {
            return nil
        }
        return stored
    }

    /// The edit to open: the draft if there is one, otherwise the committed edit.
    ///
    /// The draft wins because it is newer by construction — it is what the user was doing
    /// when the app stopped, and it is the thing they would be surprised to lose.
    public func edit<Edit: Decodable>(_ type: Edit.Type) -> Edit? {
        read(type, from: session.draftEditURL) ?? read(type, from: session.editURL)
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // A corrupt sidecar is not worth surfacing: the footage is intact, and the
            // alternative to ignoring it is refusing to open a recording that is fine.
            let name = url.lastPathComponent
            let reason = error.localizedDescription
            logger.error("Ignoring an unreadable \(name, privacy: .public): \(reason, privacy: .public)")
            return nil
        }
    }
}
