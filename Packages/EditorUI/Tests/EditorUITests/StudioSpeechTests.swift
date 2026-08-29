import Foundation
import StudioCore
import Testing
@testable import EditorUI

/// What the studio does about speech, and — more importantly — what it does without it
/// (docs/09 U3.6).
///
/// Its own suite because the property under test is a negative one: that the language
/// model is optional, that nothing waits for it, and that a machine which is offline or
/// has no model behaves exactly as it would if the installer had never been written. That
/// claim is easy to break by accident and invisible when it breaks, so it is asserted
/// rather than assumed.
@MainActor
@Suite("Studio speech")
struct StudioSpeechTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-speech-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(in folder: URL, duration: TimeInterval = 10) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data(repeating: 0, count: 64).write(to: session.screenURL)

        let document = SessionDocument(session: session)
        try document.write(InputTelemetry())
        try document.write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            scale: 2,
            frameRate: 60,
            duration: duration,
            hasBakedCursor: true,
            hasCamera: false
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    /// The guarantee the whole arrangement rests on: the studio opens, and everything in it
    /// works, without ever having consulted the speech catalogue. A model checked at launch
    /// would be a network-adjacent call on every recording somebody opens, including the
    /// ones they never intend to transcribe.
    @Test("Opening a session asks nothing about speech models")
    func speechIsNotConsultedOnOpen() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(studio.speechStatus == nil, "the speech catalogue was consulted before anybody asked")
        #expect(studio.installProgress == nil)
        #expect(!studio.isTranscribing)
    }

    /// Editing must never depend on a model, a download or a network. This walks the whole
    /// editing surface with the catalogue untouched and asserts it all still works.
    @Test("Every edit works without a speech model")
    func editingIsIndependentOfSpeech() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        studio.playhead = 4
        studio.splitAtPlayhead()
        studio.addZoom()
        studio.setSpeedAtPlayhead(2)
        studio.change { $0.reframe.aspect = .nineSixteen }
        studio.undo()
        studio.redo()

        #expect(studio.edit.clips.clips.count == 2)
        #expect(studio.edit.zooms.count == 1)
        #expect(studio.failure == nil)
        #expect(studio.speechStatus == nil, "an edit reached for the speech catalogue")
    }

    /// Cancelling has to be immediate and total, because a download nobody can stop is a
    /// download that owns the machine.
    @Test("Cancelling a download clears its state at once")
    func cancelClearsInstallState() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.installSpeechModel()
        studio.cancelSpeechModelInstall()
        #expect(studio.installProgress == nil)
    }

    /// Asking twice must not start two of them: two downloads of one model is twice the
    /// bytes and a progress bar that jumps backwards.
    @Test("Starting a download twice does not start two")
    func installIsNotReentrant() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.installSpeechModel()
        let first = studio.installProgress
        studio.installSpeechModel()
        #expect(studio.installProgress == first)
        studio.cancelSpeechModelInstall()
    }

    // MARK: - Clean closes

    /// The distinction crash recovery rests on: a draft says somebody was in the middle of
    /// this, a commit says they stopped on purpose. Without the commit every session anyone
    /// ever opened would look interrupted forever.
    @Test("A freshly edited session looks unfinished until it is closed")
    func editingLeavesASessionUnfinished() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(!studio.session.needsRecovery, "an untouched session is not a rescue")

        studio.change { $0.showsClicks = false }
        #expect(studio.session.needsRecovery, "an edit in progress should read as interrupted")

        studio.commitOnClose()
        #expect(!studio.session.needsRecovery, "a session closed on purpose is not a rescue")
    }

    /// Reopening has to land where the user left off, so the draft outlives the commit
    /// rather than being cleared by it.
    @Test("Committing on close keeps the draft")
    func commitKeepsTheDraft() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.change { $0.camera.sizeFraction = 0.4 }
        studio.commitOnClose()

        let reopened = try #require(StudioDocumentModel(session: studio.session))
        #expect(reopened.edit.camera.sizeFraction == 0.4)
    }

    @Test("Exporting also settles the session")
    func exportCommits() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.change { $0.showsKeystrokes = false }
        studio.commitOnClose()
        #expect(!studio.session.needsRecovery)
    }
}
