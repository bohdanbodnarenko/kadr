import Foundation
import Shared
import Testing
@testable import RecordingCore

/// A stitcher that does what the test needs it to.
private struct StubStitcher: SegmentStitching {
    enum Behaviour: Sendable {
        case succeed
        case fail(String)
    }

    let behaviour: Behaviour

    func stitch(_ segments: [URL], to destination: URL) async throws -> URL {
        switch behaviour {
        case .succeed:
            try Data("stitched".utf8).write(to: destination)
            return destination
        case let .fail(reason):
            throw RecordingError.writingFailed(reason)
        }
    }
}

/// The engine's stop path (docs/03 §1.8, docs/07 C3, docs/09 U0.3).
///
/// The review's coverage gap: everything upstream of `stop` needs ScreenCaptureKit and a
/// real display, so the state machine where a recording could brick had no tests at all.
/// These drive it directly through the debug seam.
@Suite("Recording lifecycle")
struct RecordingLifecycleTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-rec-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A session directory holding two finished, individually playable segments.
    private func session() throws -> (directory: URL, segments: [URL]) {
        let directory = scratch()
        let segments = try (0 ..< 2).map { index -> URL in
            let url = directory.appendingPathComponent("segment-\(index).mp4")
            try Data("segment".utf8).write(to: url)
            return url
        }
        return (directory, segments)
    }

    @Test("A successful stop returns the file and tidies up after itself")
    func successfulStop() async throws {
        let (directory, segments) = try session()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = RecordingEngine(
            stitcher: StubStitcher(behaviour: .succeed)
        )
        await engine.primeForTesting(state: .recording, segments: segments, sessionDirectory: directory)

        let destination = scratch().appendingPathComponent("out.mp4")
        let result = try await engine.stop(savingTo: destination)

        #expect(result.fileURL == destination)
        #expect(await engine.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "segments are cleaned up on success")
    }

    /// C3 in one test: the stitch fails, and the engine has to come back to `.idle` or
    /// every later recording throws while the menu bar claims to be idle.
    @Test("A failed stitch still returns the engine to idle")
    func failedStitchReturnsToIdle() async throws {
        let (directory, segments) = try session()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = RecordingEngine(
            stitcher: StubStitcher(behaviour: .fail("no space left on device"))
        )
        await engine.primeForTesting(state: .recording, segments: segments, sessionDirectory: directory)

        await #expect(throws: (any Error).self) {
            try await engine.stop(savingTo: scratch().appendingPathComponent("out.mp4"))
        }
        #expect(await engine.state == .idle, "a failed stitch must not leave the engine finishing")
    }

    @Test("A failed stitch keeps the footage and says where it is")
    func failedStitchKeepsFootage() async throws {
        let (directory, segments) = try session()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = RecordingEngine(
            stitcher: StubStitcher(behaviour: .fail("unwritable folder"))
        )
        await engine.primeForTesting(state: .recording, segments: segments, sessionDirectory: directory)

        do {
            _ = try await engine.stop(savingTo: scratch().appendingPathComponent("out.mp4"))
            Issue.record("the stitch should have failed")
        } catch let error as RecordingError {
            guard case let .stitchFailed(reason, segmentDirectory) = error else {
                Issue.record("expected a stitchFailed error, got \(error)")
                return
            }
            #expect(reason.contains("unwritable"))
            #expect(segmentDirectory == directory.path)
        }

        #expect(
            FileManager.default.fileExists(atPath: directory.path),
            "footage must survive a failed join — the segments are playable on their own"
        )
        for segment in segments {
            #expect(FileManager.default.fileExists(atPath: segment.path))
        }
    }

    /// The bricking behaviour, stated end to end: after a failure the next recording has
    /// to be startable.
    @Test("Recording is startable again after a failed stitch")
    func recordingRecoversAfterFailure() async throws {
        let (directory, segments) = try session()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = RecordingEngine(
            stitcher: StubStitcher(behaviour: .fail("disk full"))
        )
        await engine.primeForTesting(state: .recording, segments: segments, sessionDirectory: directory)
        _ = try? await engine.stop(savingTo: scratch().appendingPathComponent("out.mp4"))

        // `alreadyRecording` is the symptom the review described; anything else means the
        // state machine recovered.
        do {
            try await engine.start(target: .display(0), options: RecordingOptions())
            Issue.record("a test host cannot really start a capture")
        } catch let error as RecordingError {
            #expect(error != .alreadyRecording, "the engine was left mid-recording by the failure")
        } catch {
            // Any other error is ScreenCaptureKit refusing in a test host, which is fine.
        }
    }

    @Test("Stopping with no segments reports it and cleans up")
    func stopWithNoSegments() async throws {
        let directory = scratch()
        let engine = RecordingEngine(
            stitcher: StubStitcher(behaviour: .succeed)
        )
        await engine.primeForTesting(state: .recording, segments: [], sessionDirectory: directory)

        await #expect(throws: RecordingError.noFramesCaptured) {
            try await engine.stop(savingTo: scratch().appendingPathComponent("out.mp4"))
        }
        #expect(await engine.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Stopping when nothing is recording is refused, not crashed")
    func stopWhenIdle() async {
        let engine = RecordingEngine(stitcher: StubStitcher(behaviour: .succeed))
        await #expect(throws: RecordingError.notRecording) {
            try await engine.stop(savingTo: FileManager.default.temporaryDirectory.appendingPathComponent("x.mp4"))
        }
    }

    @Test("A paused recording can still be stopped")
    func stopWhilePaused() async throws {
        let (directory, segments) = try session()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = RecordingEngine(
            stitcher: StubStitcher(behaviour: .succeed)
        )
        await engine.primeForTesting(state: .paused, segments: segments, sessionDirectory: directory)

        let destination = scratch().appendingPathComponent("out.mp4")
        _ = try await engine.stop(savingTo: destination)
        #expect(await engine.state == .idle)
    }

    @Test("Cancelling from any state ends idle and takes the footage with it")
    func cancelCleansUp() async throws {
        let (directory, segments) = try session()
        let engine = RecordingEngine(stitcher: StubStitcher(behaviour: .succeed))
        await engine.primeForTesting(state: .recording, segments: segments, sessionDirectory: directory)

        await engine.cancel()

        #expect(await engine.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "a cancel is meant to discard")
    }

    @Test("The sample stream is bounded, so compositing lag cannot queue IOSurfaces")
    func sampleStreamIsBounded() {
        // The policy lives with the stream's creation; this pins the intent so a future
        // refactor cannot quietly restore the unbounded default (docs/07 H6).
        #expect(RecordingEngine.sampleBufferDepth == 3)
    }

    @Test("A dead stream publishes a streamStopped event")
    func streamStopPublishesEvent() async {
        let engine = RecordingEngine(stitcher: StubStitcher(behaviour: .succeed))
        let waiter: Task<RecordingEngineEvent?, Never> = Task {
            for await event in engine.events {
                return event
            }
            return nil
        }
        await engine.deliverStreamStopForTesting("The display was unplugged.")
        let event = await waiter.value
        #expect(event == RecordingEngineEvent.streamStopped("The display was unplugged."))
    }

    @Test("A failed writer still keeps a started file")
    func failedWriterKeepsTheFile() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let segment = directory.appendingPathComponent("segment-0.mp4")
        try Data("partial-take".utf8).write(to: segment)
        let writer = FailedSegmentWriter(url: segment, reason: "The disk is full.")
        let engine = RecordingEngine(
            stitcher: StubStitcher(behaviour: .succeed),
            makeWriter: { _, _, _, _ in writer }
        )
        await engine.primeForTesting(
            state: .recording,
            segments: [],
            sessionDirectory: directory,
            writer: writer
        )

        let destination = scratch().appendingPathComponent("out.mp4")
        let result = try await engine.stop(savingTo: destination)
        #expect(result.interruption == "The disk is full.")
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("An activity assertion begins on start and ends on stop")
    func activityAssertionTracksTheTake() async throws {
        let activity = CountingRecordingActivity()
        let engine = RecordingEngine(
            stitcher: StubStitcher(behaviour: .succeed),
            activity: activity
        )
        let token = await engine.beginStartForTesting()
        try await engine.finishStartForTesting(token: token)
        #expect(activity.begins == 1)
        #expect(activity.ends == 0)

        let (directory, segments) = try session()
        defer { try? FileManager.default.removeItem(at: directory) }
        await engine.primeForTesting(state: .recording, segments: segments, sessionDirectory: directory)
        _ = try await engine.stop(savingTo: scratch().appendingPathComponent("out.mp4"))
        #expect(activity.ends >= 1)
    }
}

/// A writer that has already failed but still has a file on disk (docs/16 REC-2).
private actor FailedSegmentWriter: SegmentWriting {
    let url: URL
    let failureReason: String?

    init(url: URL, reason: String) {
        self.url = url
        failureReason = reason
    }

    var duration: TimeInterval {
        2
    }

    func append(_: SampleBufferBox) -> Bool {
        false
    }

    func finish() async -> URL? {
        url
    }

    func cancel() {}
}
