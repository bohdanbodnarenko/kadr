import CoreGraphics
import Foundation
import Testing
@testable import StudioSession

/// Reading and writing a session's sidecars (docs/09 U3.1).
@Suite("Session documents")
struct SessionDocumentTests {
    private struct StubEdit: Codable, Equatable {
        var zoomCount: Int
        var title: String
    }

    /// A session, its document and the root to clean up.
    private struct Scratch {
        var session: RecordingSession
        var document: SessionDocument
        var root: URL
    }

    private func scratch() throws -> Scratch {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = RecordingSession.create(in: root, named: "Recording")
        try session.create()
        return Scratch(session: session, document: SessionDocument(session: session), root: root)
    }

    // MARK: - Round trips

    @Test("Telemetry round-trips")
    func telemetryRoundTrips() throws {
        let scratch = try scratch()
        let (document, root) = (scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        let telemetry = InputTelemetry(
            pointer: [PointerSample(time: 1, position: CGPoint(x: 10, y: 20))],
            clicks: [ClickEvent(time: 1.2, position: CGPoint(x: 10, y: 20))],
            keystrokes: [KeystrokeEvent(time: 2, caption: "⌘S")],
            source: .eventTap
        )
        try document.write(telemetry)
        #expect(document.telemetry() == telemetry)
    }

    @Test("The manifest round-trips")
    func manifestRoundTrips() throws {
        let scratch = try scratch()
        let (document, root) = (scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = CaptureManifest(pixelSize: CGSize(width: 2560, height: 1440), duration: 42)
        try document.write(manifest)
        #expect(document.manifest() == manifest)
    }

    // MARK: - Drafts

    /// The draft is newer by construction — it is what the user was doing when the app
    /// stopped, and the thing they would be surprised to lose.
    @Test("The draft wins over the committed edit when both exist")
    func draftWins() throws {
        let scratch = try scratch()
        let (document, root) = (scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try document.commit(StubEdit(zoomCount: 1, title: "committed"))
        try document.writeDraft(StubEdit(zoomCount: 5, title: "draft"))

        #expect(document.edit(StubEdit.self)?.title == "draft")
        let committed = try JSONDecoder().decode(
            StubEdit.self,
            from: Data(contentsOf: scratch.session.editURL)
        )
        #expect(committed.title == "committed")
    }

    @Test("With no draft the committed edit is what opens")
    func committedOpensWithoutADraft() throws {
        let scratch = try scratch()
        let (document, root) = (scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try document.commit(StubEdit(zoomCount: 1, title: "committed"))
        #expect(document.edit(StubEdit.self)?.title == "committed")
    }

    /// Committing clears the draft: leaving it behind would make the session look
    /// permanently unrecovered.
    @Test("Committing clears the draft it came from")
    func committingClearsTheDraft() throws {
        let scratch = try scratch()
        let (session, document, root) = (scratch.session, scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try document.writeDraft(StubEdit(zoomCount: 5, title: "draft"))
        try document.commit(StubEdit(zoomCount: 5, title: "committed"))

        #expect(!FileManager.default.fileExists(atPath: session.draftEditURL.path))
        #expect(!session.needsRecovery)
    }

    @Test("Nothing written reads as nothing")
    func nothingWritten() throws {
        let scratch = try scratch()
        let (document, root) = (scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(document.telemetry() == nil)
        #expect(document.manifest() == nil)
        #expect(document.edit(StubEdit.self) == nil)
    }

    /// The footage is intact; refusing to open a recording because a sidecar is corrupt
    /// would be refusing a recording that is fine.
    @Test("A corrupt sidecar is ignored rather than fatal")
    func corruptSidecar() throws {
        let scratch = try scratch()
        let (session, document, root) = (scratch.session, scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("not json".utf8).write(to: session.inputURL)
        #expect(document.telemetry() == nil)
    }

    // MARK: - The render stamp

    /// Exporting is minutes of work. Doing it twice is minutes wasted; not doing it when
    /// something changed is a wrong file shipped.
    @Test("The same edit produces the same digest")
    func digestIsStable() {
        let edit = StubEdit(zoomCount: 3, title: "one")
        #expect(RenderStamp.digest(of: edit) == RenderStamp.digest(of: edit))
    }

    @Test("Any change produces a different digest")
    func digestChangesWithTheEdit() {
        let first = RenderStamp.digest(of: StubEdit(zoomCount: 3, title: "one"))
        let second = RenderStamp.digest(of: StubEdit(zoomCount: 4, title: "one"))
        #expect(first != second)
    }

    @Test("A stamp matches the render it describes")
    func stampMatches() throws {
        let scratch = try scratch()
        let root = scratch.root
        defer { try? FileManager.default.removeItem(at: root) }

        let output = root.appendingPathComponent("out.mp4")
        try Data("movie".utf8).write(to: output)
        let stamp = RenderStamp(
            editDigest: "abc",
            outputPath: output.path,
            pixelSize: CGSize(width: 1920, height: 1080)
        )

        #expect(stamp.matches(editDigest: "abc", pixelSize: CGSize(width: 1920, height: 1080)))
        #expect(!stamp.matches(editDigest: "xyz", pixelSize: CGSize(width: 1920, height: 1080)))
        #expect(!stamp.matches(editDigest: "abc", pixelSize: CGSize(width: 1280, height: 720)))
    }

    @Test("A stamp with export settings does not match a different encode")
    func stampSettingsDigest() throws {
        let scratch = try scratch()
        let root = scratch.root
        defer { try? FileManager.default.removeItem(at: root) }

        let output = root.appendingPathComponent("out.mov")
        try Data("movie".utf8).write(to: output)
        let stamp = RenderStamp(
            editDigest: "abc",
            outputPath: output.path,
            pixelSize: CGSize(width: 1920, height: 1080),
            settingsDigest: "hevc-high"
        )

        #expect(stamp.matches(
            editDigest: "abc",
            pixelSize: CGSize(width: 1920, height: 1080),
            settingsDigest: "hevc-high"
        ))
        #expect(!stamp.matches(
            editDigest: "abc",
            pixelSize: CGSize(width: 1920, height: 1080),
            settingsDigest: "h264-low"
        ))
    }

    @Test("An empty digest is a miss, even against another empty digest")
    func emptyDigestNeverMatches() {
        let stamp = RenderStamp(editDigest: "", outputPath: "/tmp/out.mp4", pixelSize: .zero)
        #expect(!stamp.matches(editDigest: "", pixelSize: .zero))
    }

    /// A stamp naming a file the user has since moved is a stamp for nothing.
    @Test("A stamp whose file has gone does not match")
    func stampWithoutItsFile() {
        let stamp = RenderStamp(
            editDigest: "abc",
            outputPath: "/nowhere/out.mp4",
            pixelSize: CGSize(width: 1920, height: 1080)
        )
        #expect(!stamp.matches(editDigest: "abc", pixelSize: CGSize(width: 1920, height: 1080)))
    }

    @Test("A stamp round-trips")
    func stampRoundTrips() throws {
        let scratch = try scratch()
        let (document, root) = (scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        let stamp = RenderStamp(editDigest: "abc", outputPath: "/tmp/out.mp4", pixelSize: .zero)
        try document.write(stamp)
        #expect(document.renderStamp() == stamp)
    }

    @Test("A transcript round-trips and invalidates on a different hash")
    func transcriptSidecar() throws {
        let scratch = try scratch()
        let (document, root) = (scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = Transcript(
            words: [TranscriptWord(text: "Hello", start: 0, end: 1)],
            audioContentHash: "abc"
        )
        try document.write(transcript)
        #expect(document.transcript()?.words.first?.text == "Hello")
        #expect(document.transcript(matchingHash: "abc") != nil)
        #expect(document.transcript(matchingHash: "other") == nil)
    }

    // MARK: - Footage hash cache

    /// Whether a transcript survives reopening, by what happened to the footage in between.
    enum FootageChange: String, CaseIterable, Sendable {
        case untouched
        case rewrittenWithDifferentBytes
        case rewrittenWithSameBytes
    }

    @Test("A stored transcript is kept or dropped by what the footage now is", arguments: FootageChange.allCases)
    func transcriptFollowsFootage(change: FootageChange) throws {
        let scratch = try scratch()
        let (session, document, root) = (scratch.session, scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = Data(repeating: 7, count: 4096)
        try original.write(to: session.screenURL)
        let hash = try AudioContentHash.hash(fileAt: session.screenURL)
        try document.write(Transcript(words: [TranscriptWord(text: "Hi", start: 0, end: 1)], audioContentHash: hash))
        #expect(try document.transcriptMatchingFootage() != nil)

        switch change {
        case .untouched:
            break
        case .rewrittenWithDifferentBytes:
            try Data(repeating: 9, count: 4096).write(to: session.screenURL, options: .atomic)
        case .rewrittenWithSameBytes:
            try original.write(to: session.screenURL, options: .atomic)
        }

        let expectKept = change != .rewrittenWithDifferentBytes
        #expect(try (document.transcriptMatchingFootage() != nil) == expectKept)
    }

    /// The point of the cache: a matching identity is trusted without reading the file.
    /// Proven by planting a hash that the bytes would never produce and seeing it returned.
    @Test("An unchanged file reuses the remembered hash without reading it")
    func unchangedFileSkipsHashing() throws {
        let scratch = try scratch()
        let (session, document, root) = (scratch.session, scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 1, count: 128).write(to: session.screenURL)
        let real = try document.audioContentHash()
        #expect(document.audioHashCache()?.hash == real, "the first hash was not remembered")

        let identity = try #require(AudioFileIdentity(fileAt: session.screenURL))
        try document.write(AudioContentHashCache(identity: identity, hash: "planted"))
        #expect(try document.audioContentHash() == "planted")

        // Any change to the identity is a miss, and the miss re-hashes.
        var stale = identity
        stale.byteCount += 1
        try document.write(AudioContentHashCache(identity: stale, hash: "planted"))
        #expect(try document.audioContentHash() == real)
    }

    @Test("A transcript with no recorded hash is trusted without hashing")
    func unhashedTranscriptIsTrusted() throws {
        let scratch = try scratch()
        let (document, root) = (scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }
        // No footage at all: hashing would fail, so reaching it would drop the transcript.
        try document.write(Transcript(words: [TranscriptWord(text: "Hi", start: 0, end: 1)]))
        #expect(try document.transcriptMatchingFootage() != nil)
        #expect(document.audioHashCache() == nil, "hashed a file nobody needed hashed")
    }

    @Test("No transcript means nothing is read")
    func noTranscriptNoHash() throws {
        let scratch = try scratch()
        let (session, document, root) = (scratch.session, scratch.document, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 128).write(to: session.screenURL)
        #expect(try document.transcriptMatchingFootage() == nil)
        #expect(document.audioHashCache() == nil)
    }

    @Test("Hashing a file stops when its task is cancelled")
    func hashingIsCancellable() async throws {
        let scratch = try scratch()
        let (session, root) = (scratch.session, scratch.root)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 128).write(to: session.screenURL)
        let url = session.screenURL
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AudioContentHash.hash(fileAt: url)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// What is captured alongside the footage (docs/09 U3.1).
@Suite("Input telemetry")
struct InputTelemetryTests {
    @Test("An empty sidecar knows it is empty")
    func emptyTelemetry() {
        #expect(InputTelemetry().isEmpty)
        #expect(InputTelemetry().duration == 0)
    }

    @Test("Duration is the last thing that happened")
    func duration() {
        let telemetry = InputTelemetry(
            pointer: [PointerSample(time: 1, position: .zero)],
            clicks: [ClickEvent(time: 4.5, position: .zero)],
            keystrokes: [KeystrokeEvent(time: 2, caption: "⌘S")]
        )
        #expect(telemetry.duration == 4.5)
    }

    /// A sidecar written by a later Kadr still opens — it simply arrives without whatever
    /// was added.
    @Test("Unknown fields are ignored, not fatal")
    func unknownFieldsAreIgnored() throws {
        let json = #"{"version": 9, "pointer": [], "gestures": [{"kind": "pinch"}]}"#
        let telemetry = try JSONDecoder().decode(InputTelemetry.self, from: Data(json.utf8))
        #expect(telemetry.version == 9)
        #expect(telemetry.isEmpty)
    }

    @Test("A sidecar with nothing in it at all decodes")
    func emptyObject() throws {
        let telemetry = try JSONDecoder().decode(InputTelemetry.self, from: Data("{}".utf8))
        #expect(telemetry.isEmpty)
        #expect(telemetry.source == .eventTap)
    }

    // MARK: - The fallback ladder

    /// Each layer can fail independently and silently, so a reconstruction has to be able
    /// to explain itself rather than just looking bad.
    @Test("Every source has a title", arguments: TelemetrySource.allCases)
    func sourcesExplainThemselves(source: TelemetrySource) {
        #expect(!source.title.isEmpty)
    }

    /// A recording's sidecar must never become a keylogger: only chords and special keys
    /// are captured, so there is nothing in the file to leak or redact.
    @Test("A keystroke carries a caption, not a character stream")
    func keystrokesAreCaptions() {
        let event = KeystrokeEvent(time: 1, caption: "⇧⌘4")
        #expect(event.caption == "⇧⌘4")
    }

    @Test("Cursor artwork carries its hotspot, so it points where it pointed")
    func cursorHotspot() {
        let cursor = CursorImage(
            pngData: Data([0x89, 0x50]),
            hotspot: CGPoint(x: 4, y: 2),
            size: CGSize(width: 24, height: 24)
        )
        #expect(cursor.hotspot == CGPoint(x: 4, y: 2))
    }

    /// Reconstruction needs a clean plate: a cursor already in the pixels cannot be
    /// smoothed, moved, or scaled with a zoom.
    @Test("A manifest records whether the cursor is baked in")
    func bakedCursor() {
        #expect(!CaptureManifest(pixelSize: .zero).hasBakedCursor)
        #expect(CaptureManifest(pixelSize: .zero, hasBakedCursor: true).hasBakedCursor)
    }
}
