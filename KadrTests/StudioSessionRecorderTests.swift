import Foundation
import RecordingCore
import Shared
import StudioSession
import Testing
@testable import Kadr

/// The sidecar captured beside a recording (docs/09 U3.1).
///
/// The parts tested here are the ones that decide whether an edit is possible later: that
/// the footage really is attached, that the manifest remembers what cannot be re-derived,
/// and that a failure leaves no half-built package behind.
///
/// The clock is tested too, and it was not. This file used to say telemetry capture "needs
/// an event tap and a real pointer" and stopped there — true of the tap, false of the
/// clock, which is a number with a setter. A frozen clock made every event in the sidecar
/// land at zero and the sample-rate gate reject everything after the first sample, and this
/// suite passed throughout (docs/10 R0.1).
@MainActor
@Suite("Studio session recorder")
struct StudioSessionRecorderTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recording(at url: URL, duration: TimeInterval = 3, showsCursor: Bool = true) -> RecordingResult {
        RecordingResult(
            fileURL: url,
            duration: duration,
            pixelSize: PixelSize(width: 1920, height: 1080),
            options: RecordingOptions(
                frameRate: .sixty,
                codec: .hevc,
                capturesSystemAudio: true,
                capturesMicrophone: false,
                showsCursor: showsCursor
            )
        )
    }

    // MARK: - Where sessions live

    /// Not the temporary directory: macOS purges that on its own schedule, and a session
    /// holding the only copy of an unfinished edit is not something to leave there.
    @Test("Sessions live in Application Support, not a purgeable directory")
    func rootIsDurable() throws {
        let root = try #require(StudioSessionRecorder.root())
        #expect(root.path.contains("Application Support"))
        #expect(!root.path.hasPrefix("/tmp"))
        #expect(!root.path.contains("/T/"), "the temporary directory is swept by the system")
    }

    // MARK: - Attaching footage

    @Test("The recording is attached without writing a second copy of it")
    func footageIsLinkedNotCopied() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let footage = folder.appendingPathComponent("recording.mp4")
        try Data(repeating: 7, count: 4096).write(to: footage)

        let session = RecordingSession.create(in: folder, named: "attach")
        try session.create()
        let recorder = StudioSessionRecorder()
        #expect(await recorder.attachForTesting(footage, to: session))

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: session.screenURL.path))

        // Same inode: the bytes exist once and both paths are real files, so neither
        // deleting the user's recording nor sweeping the session takes the other with it.
        let footageID = try manager.attributesOfItem(atPath: footage.path)[.systemFileNumber] as? Int
        let linkedID = try manager.attributesOfItem(atPath: session.screenURL.path)[.systemFileNumber] as? Int
        #expect(footageID != nil)
        #expect(footageID == linkedID, "the recording was copied rather than linked")
    }

    @Test("Deleting the user's recording leaves the session's footage readable")
    func linkSurvivesDeletion() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let footage = folder.appendingPathComponent("recording.mp4")
        let payload = Data(repeating: 3, count: 2048)
        try payload.write(to: footage)

        let session = RecordingSession.create(in: folder, named: "survives")
        try session.create()
        let recorder = StudioSessionRecorder()
        #expect(await recorder.attachForTesting(footage, to: session))
        try FileManager.default.removeItem(at: footage)

        #expect(try Data(contentsOf: session.screenURL) == payload)
    }

    @Test("Attaching a recording that is not there fails rather than pretending")
    func missingFootage() async {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = RecordingSession.create(in: folder, named: "missing")
        try? session.create()
        let recorder = StudioSessionRecorder()
        let attached = await recorder.attachForTesting(folder.appendingPathComponent("nope.mp4"), to: session)
        #expect(!attached)
    }

    // MARK: - Finishing

    @Test("A finished session has its footage, its telemetry and its manifest")
    func finishedSessionIsComplete() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let footage = folder.appendingPathComponent("recording.mp4")
        try Data(repeating: 1, count: 1024).write(to: footage)

        let recorder = StudioSessionRecorder()
        let session = try #require(recorder.startForTesting(in: folder))
        let finished = try #require(await recorder.finish(with: recording(at: footage)))
        defer { try? finished.delete() }

        #expect(finished.directory == session.directory)
        #expect(finished.hasFootage)

        let document = SessionDocument(session: finished)
        #expect(document.telemetry() != nil, "the sidecar is the whole point of the session")
        let manifest = try #require(document.manifest())
        #expect(manifest.duration == 3)
        #expect(manifest.frameRate == 60)
        #expect(manifest.pixelSize == CGSize(width: 1920, height: 1080))
    }

    /// Recorded rather than worked out later: whether the studio should draw a cursor
    /// depends on whether one is already in the picture, and by the time anybody opens the
    /// editor there is no way left to tell.
    @Test("The manifest remembers whether the cursor was baked in", arguments: [true, false])
    func manifestRemembersTheCursor(baked: Bool) async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let footage = folder.appendingPathComponent("recording.mp4")
        try Data(repeating: 1, count: 512).write(to: footage)

        let recorder = StudioSessionRecorder()
        _ = recorder.startForTesting(in: folder)
        let finished = try #require(
            await recorder.finish(with: recording(at: footage, showsCursor: baked))
        )
        defer { try? finished.delete() }

        let manifest = try #require(SessionDocument(session: finished).manifest())
        #expect(manifest.hasBakedCursor == baked)
    }

    @Test("A session with no camera says so")
    func manifestRemembersNoCamera() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let footage = folder.appendingPathComponent("recording.mp4")
        try Data(repeating: 1, count: 512).write(to: footage)

        let recorder = StudioSessionRecorder()
        _ = recorder.startForTesting(in: folder)
        let finished = try #require(await recorder.finish(with: recording(at: footage)))
        defer { try? finished.delete() }
        #expect(SessionDocument(session: finished).manifest()?.hasCamera == false)
    }

    /// A package with no footage in it is worse than no package: it survives the sweep,
    /// shows up as a recoverable session, and opens to nothing.
    @Test("A session whose footage could not be attached is removed rather than left behind")
    func failedAttachLeavesNothing() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = StudioSessionRecorder()
        let session = try #require(recorder.startForTesting(in: folder))

        let missing = folder.appendingPathComponent("never-written.mp4")
        #expect(await recorder.finish(with: recording(at: missing)) == nil)
        #expect(!session.exists, "an empty session package was left behind")
    }

    @Test("Cancelling removes the session")
    func cancelRemovesTheSession() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = StudioSessionRecorder()
        let session = try #require(recorder.startForTesting(in: folder))
        recorder.cancel()
        #expect(!session.exists)
        #expect(recorder.current == nil)
    }

    @Test("Finishing without having started reports nothing rather than inventing a session")
    func finishWithoutStart() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let footage = folder.appendingPathComponent("recording.mp4")
        try Data(repeating: 1, count: 16).write(to: footage)
        #expect(await StudioSessionRecorder().finish(with: recording(at: footage)) == nil)
    }
}
