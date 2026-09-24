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
        #expect(names.contains("transcript.json"))
        #expect(names.contains("project.json"))
    }

    @Test("An imported soundtrack is copied into the session")
    func soundtrackIsCopiedIn() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let source = root.appendingPathComponent("voice.wav")
        try Data("audio".utf8).write(to: source)

        let name = try session.replaceSoundtrack(copying: source)
        #expect(name.hasPrefix("soundtrack-") && name.hasSuffix(".wav"))
        #expect(session.soundtrackURLs.count == 1)
        #expect(FileManager.default.fileExists(atPath: session.soundtrackURLs[0].path))

        var edit = StudioEdit.untouched(duration: 1)
        edit.soundtrackFileName = name
        #expect(session.soundtrackURL(for: edit) == session.soundtrackURLs[0])

        try session.removeSoundtracks()
        #expect(session.soundtrackURLs.isEmpty)
        #expect(session.soundtrackURL(for: edit) == nil)
    }

    @Test("An imported wallpaper is copied into the session")
    func wallpaperIsCopiedIn() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let source = root.appendingPathComponent("bg.png")
        try Data("image".utf8).write(to: source)

        let name = try session.replaceWallpaper(copying: source)
        #expect(name.hasPrefix("wallpaper-") && name.hasSuffix(".png"))
        #expect(session.wallpaperURLs.count == 1)

        var edit = StudioEdit.untouched(duration: 1)
        edit.canvas.wallpaperFileName = name
        #expect(session.wallpaperURL(for: edit) == session.wallpaperURLs[0])

        try session.removeWallpapers()
        #expect(session.wallpaperURLs.isEmpty)
        #expect(session.wallpaperURL(for: edit) == nil)
    }

    /// docs/17 T-STU-1: a different file is a different name, so the edit — and the
    /// render stamp's digest of it — changes when the wallpaper or soundtrack is swapped.
    @Test("Imports are content-addressed and unused ones are purged on commit")
    func importsAreContentAddressed() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        let first = root.appendingPathComponent("a.png")
        let second = root.appendingPathComponent("b.png")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        let firstName = try session.replaceWallpaper(copying: first)
        let again = try session.replaceWallpaper(copying: first)
        let secondName = try session.replaceWallpaper(copying: second)
        #expect(firstName == again)
        #expect(firstName != secondName)
        // The replaced file stays until commit, so undo still finds it (T-STU-9).
        #expect(session.wallpaperURLs.count == 2)

        var edit = StudioEdit.untouched(duration: 1)
        edit.canvas.wallpaperFileName = secondName
        session.purgeUnusedImports(keeping: edit)
        #expect(session.wallpaperURLs.count == 1)
        #expect(session.wallpaperURL(for: edit) != nil)
    }

    @Test("A session is named for its folder until it is renamed")
    func displayNameDefaultsToTheFolder() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, named: "2026-09-01-142233")
        #expect(session.displayName == "2026-09-01-142233")
        try session.setDisplayName("  Onboarding walkthrough  ")
        #expect(session.displayName == "Onboarding walkthrough")
        try session.setDisplayName("   ")
        #expect(session.displayName == "Onboarding walkthrough", "a blank rename must not hide the project")
    }

    @Test("Project titles match footage by identity, not by path")
    func displayNamesMatchHardLinkedFootage() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, named: "session")
        try Data("movie".utf8).write(to: session.screenURL)
        try session.setDisplayName("Demo")
        let alias = root.appendingPathComponent("elsewhere.mov")
        try FileManager.default.linkItem(at: session.screenURL, to: alias)
        let names = RecordingSessionStore(root: root).displayNames(forFootageAt: [alias])
        #expect(names[alias.standardizedFileURL.path] == "Demo")
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

    @Test("Footage without a capture sidecar needs recovering")
    func needsCaptureRecovery() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        try writeFootage(session)

        #expect(session.needsCaptureRecovery)
        try Data("{}".utf8).write(to: session.captureURL)
        #expect(!session.needsCaptureRecovery)
    }

    @Test("A camera file without screen footage is still media")
    func cameraOnlyHasMedia() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root)
        try Data("camera".utf8).write(to: session.cameraURL)

        #expect(!session.hasFootage)
        #expect(session.hasMedia)
        #expect(RecordingSessionStore(root: root).sweepEmpty() == 0)
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
