import CoreGraphics
import Foundation
import Testing
@testable import StudioSession

/// The session package on disk (docs/09 U3.1).
///
/// A directory rather than a file, because a studio recording is several streams that have
/// to stay in step and a single container would mean rewriting all of it to change one
/// number. These tests are about that directory behaving: what is in it, what a crash
/// leaves behind, and what may be swept.
@Suite("Recording session")
struct RecordingSessionTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-studio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSession(in root: URL, named name: String = "Recording") throws -> RecordingSession {
        let session = RecordingSession.create(in: root, named: name)
        try session.create()
        return session
    }

    private func writeFootage(_ session: RecordingSession) throws {
        try Data("movie".utf8).write(to: session.screenURL)
    }

    // MARK: - Layout

    @Test("A session is a directory with a known extension")
    func sessionIsADirectory() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)

        #expect(session.directory.pathExtension == RecordingSession.fileExtension)
        #expect(session.exists)
    }

    @Test("Every part has its own place")
    func parts() {
        let session = RecordingSession(directory: URL(fileURLWithPath: "/tmp/x.kadrrec"))
        let names = Set(session.allURLs.map(\.lastPathComponent))

        #expect(names.contains("screen.mov"))
        #expect(names.contains("camera.mov"))
        #expect(names.contains("input.json"))
        #expect(names.contains("input.jsonl"))
        #expect(names.contains("capture.json"))
        #expect(names.contains("edit.json"))
        #expect(names.contains("edit.draft.json"))
        #expect(names.contains("render.json"))
        #expect(names.contains("poster.jpg"))
    }

    /// The draft is separate from the committed edit on purpose: an autosave that
    /// overwrote the commit would make "revert" impossible and turn a crash mid-drag into
    /// a permanent change.
    @Test("The draft and the committed edit are different files")
    func draftIsSeparate() {
        let session = RecordingSession(directory: URL(fileURLWithPath: "/tmp/x.kadrrec"))
        #expect(session.editURL != session.draftEditURL)
    }

    /// Application Support rather than the temporary directory: `/tmp` is purged on a
    /// schedule nobody controls, and handing a user's unfinished recording to the purger
    /// is not a risk worth taking.
    @Test("Sessions live in Application Support, not the temporary directory")
    func sessionsLiveInApplicationSupport() {
        let root = RecordingSession.defaultRoot(applicationSupport: URL(fileURLWithPath: "/Support"))
        #expect(root.path.hasPrefix("/Support/Kadr"))
        #expect(!root.path.contains("tmp"))
    }

    // MARK: - Recovery

    @Test("Footage is what makes a session worth anything")
    func hasFootage() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)

        #expect(!session.hasFootage)
        try writeFootage(session)
        #expect(session.hasFootage)
    }

    /// Footage plus a draft and no commit is a session that was open when something went
    /// wrong — the case recovery exists for.
    @Test("A session left open by a crash needs recovering")
    func needsRecovery() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        try writeFootage(session)
        try Data("{}".utf8).write(to: session.draftEditURL)

        #expect(session.needsRecovery)
    }

    /// A session with a committed edit was finished with at some point; reopening it is
    /// the user's business rather than a rescue.
    @Test("A committed session does not need recovering")
    func committedDoesNotNeedRecovery() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        try writeFootage(session)
        try Data("{}".utf8).write(to: session.draftEditURL)
        try Data("{}".utf8).write(to: session.editURL)

        #expect(!session.needsRecovery)
    }

    @Test("A session with no footage never needs recovering")
    func emptyDoesNotNeedRecovery() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        try Data("{}".utf8).write(to: session.draftEditURL)

        #expect(!session.needsRecovery)
    }

    // MARK: - The store

    @Test("The store finds every session")
    func findingSessions() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeSession(in: root, named: "One")
        _ = try makeSession(in: root, named: "Two")

        #expect(RecordingSessionStore(root: root).sessions().count == 2)
    }

    @Test("Anything that is not a session is ignored")
    func ignoresOtherFiles() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeSession(in: root)
        try Data("stray".utf8).write(to: root.appendingPathComponent("notes.txt"))

        #expect(RecordingSessionStore(root: root).sessions().count == 1)
    }

    @Test("The store finds the ones a crash left open")
    func findingRecoverable() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let crashed = try makeSession(in: root, named: "Crashed")
        try writeFootage(crashed)
        try Data("{}".utf8).write(to: crashed.draftEditURL)
        let finished = try makeSession(in: root, named: "Finished")
        try writeFootage(finished)

        let recoverable = RecordingSessionStore(root: root).sessionsNeedingRecovery()
        #expect(recoverable.count == 1)
        #expect(recoverable[0].directory.lastPathComponent.hasPrefix("Crashed"))
    }

    /// A directory created for a recording that failed before writing a frame is litter;
    /// one with footage is somebody's work and is never swept on age alone.
    @Test("Sweeping removes the empty ones and keeps the footage")
    func sweeping() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeSession(in: root, named: "Empty")
        let full = try makeSession(in: root, named: "Full")
        try writeFootage(full)

        let store = RecordingSessionStore(root: root)
        #expect(store.sweepEmpty() == 1)
        #expect(store.sessions().count == 1)
        #expect(full.hasFootage)
    }

    @Test("A missing root is not an error, just no sessions")
    func missingRoot() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-absent-\(UUID().uuidString)")
        #expect(RecordingSessionStore(root: missing).sessions().isEmpty)
        #expect(RecordingSessionStore(root: missing).sweepEmpty() == 0)
    }

    @Test("Deleting takes the whole package")
    func deleting() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        try writeFootage(session)

        try session.delete()
        #expect(!session.exists)
    }

    @Test("A session reports its size")
    func byteCount() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        try Data(count: 1024).write(to: session.screenURL)

        #expect(session.byteCount >= 1024)
    }
}
