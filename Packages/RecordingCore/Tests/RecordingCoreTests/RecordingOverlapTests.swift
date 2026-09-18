import Foundation
import Shared
import Testing
@testable import RecordingCore

/// A writer whose `finish()` the test decides when to complete.
///
/// Every race in docs/11 S0.3 lives inside the window where `finish()` is suspended. In
/// production that window is 100–300 ms of `AVAssetWriter` finalising an MP4 — long enough
/// for a user to press Pause and then Stop inside it, and far too unpredictable to write a
/// test against. Holding the window open on purpose is what turns the bug from something
/// that reproduces once in fifty tries into something that reproduces every time.
private actor GatedWriter: SegmentWriting {
    let url: URL
    private let length: TimeInterval
    /// What `finish` was asked to trim, so a test can see the stop's tail arrive.
    private(set) var trimmed: TimeInterval = 0
    private var release: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var finishCount = 0
    private(set) var durationReads = 0

    init(url: URL, length: TimeInterval = 5) {
        self.url = url
        self.length = length
    }

    var duration: TimeInterval {
        durationReads += 1
        return max(length - trimmed, 0)
    }

    var failureReason: String? {
        nil
    }

    func append(_: SampleBufferBox) -> Bool {
        true
    }

    func finish(trimmingTail tail: TimeInterval) async -> URL? {
        finishCount += 1
        trimmed = tail
        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    release = continuation
                }
            }
        }
        try? Data("segment".utf8).write(to: url)
        return url
    }

    func cancel() {}

    /// Lets the in-flight `finish()` complete.
    func releaseFinish() {
        isReleased = true
        release?.resume()
        release = nil
    }

    /// Waits until `finish()` has actually been entered, so the test's second call really
    /// does land inside the window rather than before it.
    func waitUntilFinishing() async {
        while finishCount == 0 {
            await Task.yield()
        }
    }
}

/// Overlapping lifecycle commands (docs/11 S0.3, S1 test 3).
///
/// Pause/Stop, Cancel/Start and Stop-during-start are all ordinary things for a user to
/// do — the whole point is that they happen inside a window the user cannot see. None of
/// these need a display or a TCC grant, which is the reason the state machine could carry
/// three races into a release candidate with 1,688 tests passing.
@Suite("Recording overlap")
struct RecordingOverlapTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-overlap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func primed(_ writer: GatedWriter, in directory: URL) async -> RecordingEngine {
        let engine = RecordingEngine(stitcher: StubOverlapStitcher())
        await engine.primeForTesting(
            state: .recording,
            segments: [],
            sessionDirectory: directory,
            writer: writer
        )
        return engine
    }

    // MARK: - Pause, then Stop

    /// The headline race. `pause()` sets `.paused` and suspends inside `closeSegment()`;
    /// `stop()` accepts `.paused` and used to call it again on the same writer, adding the
    /// same segment's length to `accumulatedDuration` twice. The inflated figure is written
    /// into `CaptureManifest.duration` verbatim and becomes the studio timeline's length,
    /// so the playhead scrubs into footage that does not exist.
    @Test("Pausing and stopping inside the same segment counts its length once")
    func pauseThenStopCountsDurationOnce() async {
        let directory = scratch()
        let writer = GatedWriter(url: directory.appendingPathComponent("segment-0.mp4"), length: 5)
        let engine = await primed(writer, in: directory)

        async let paused: Void? = try? await engine.pause()
        await writer.waitUntilFinishing()
        // Inside the window now: the pause is suspended in `finishWriting`.
        async let stopped = try? await engine.stop(savingTo: directory.appendingPathComponent("out.mp4"))
        await writer.releaseFinish()
        _ = await paused
        let result = await stopped

        #expect(await engine.accumulatedDurationForTesting == 5, "the segment was counted more than once")
        #expect(result?.duration == 5)
    }

    /// The other half of the same race, and the one that loses footage rather than
    /// miscounting it: if Stop does not *wait* for the Pause's close, it stitches a
    /// `segments` array the pause has not finished appending to.
    @Test("Stopping during a pause still stitches the segment the pause was closing")
    func stopWaitsForThePausesSegment() async {
        let directory = scratch()
        let writer = GatedWriter(url: directory.appendingPathComponent("segment-0.mp4"))
        let engine = await primed(writer, in: directory)

        async let paused: Void? = try? await engine.pause()
        await writer.waitUntilFinishing()
        async let stopped = try? await engine.stop(savingTo: directory.appendingPathComponent("out.mp4"))
        await writer.releaseFinish()
        _ = await paused

        #expect(await stopped != nil, "the recording was dropped because its only segment had not landed yet")
        #expect(await writer.finishCount == 1, "the same writer was finalised twice")
    }

    /// `finish()` claimed to be safe to call twice, and was not: it set `isFinished` before
    /// its own suspension, so the second caller was handed the URL of a file still being
    /// written and went off to stitch it.
    @Test("A second finish waits for the first rather than returning early")
    func secondFinishWaitsForTheFirst() async throws {
        let directory = scratch()
        let writer = GatedWriter(url: directory.appendingPathComponent("segment-0.mp4"))

        async let first = writer.finish(trimmingTail: 0)
        await writer.waitUntilFinishing()
        async let second = writer.finish(trimmingTail: 0)
        await writer.releaseFinish()

        let one = try #require(await first)
        let two = await second
        #expect(one == two)
        // Whoever gets the URL must be able to read the file.
        #expect(FileManager.default.fileExists(atPath: one.path))
    }

    // MARK: - Cancel, then the start it interrupted

    /// `.starting` is `isActive`, so `cancel()` runs *while* `engine.start` is suspended in
    /// ScreenCaptureKit. It nils the writer, deletes the session and sets `.idle` — and the
    /// start then resumed and set `.recording` on top of it. The result was a recording
    /// that existed only in the menu bar: every frame dropped, desktop icons still hidden,
    /// and Stop reporting `noFramesCaptured`.
    @Test("A start that was cancelled while it was suspended does not claim the recording")
    func cancelDuringStartLeavesNoPhantom() async {
        let engine = RecordingEngine(stitcher: StubOverlapStitcher())
        let token = await engine.beginStartForTesting()
        #expect(await engine.state == .starting)

        await engine.cancel()
        #expect(await engine.state == .idle)

        // The start now resumes from its suspension.
        await #expect(throws: RecordingError.cancelledDuringStart) {
            try await engine.finishStartForTesting(token: token)
        }
        #expect(await engine.state == .idle, "a cancelled start resurrected itself as .recording")
    }

    /// The generation check must not fire on the ordinary path, or every recording would
    /// refuse to start.
    @Test("An uninterrupted start claims the recording")
    func uninterruptedStartClaimsTheRecording() async throws {
        let engine = RecordingEngine(stitcher: StubOverlapStitcher())
        let token = await engine.beginStartForTesting()
        try await engine.finishStartForTesting(token: token)
        #expect(await engine.state == .recording)
    }

    /// `.starting` is claimed before the first suspension, so the second press is refused
    /// by the engine and not merely by the coordinator.
    @Test("A second start during setup is refused")
    func secondStartDuringSetupIsRefused() async {
        let engine = RecordingEngine(stitcher: StubOverlapStitcher())
        _ = await engine.beginStartForTesting()

        await #expect(throws: RecordingError.alreadyRecording) {
            try await engine.start(target: .display(0), options: RecordingOptions())
        }
    }

    // MARK: - Resume racing the pause that preceded it

    /// Resume used to open the next segment while the previous one was still finalising,
    /// so the two raced to append and the recording stitched back together out of order.
    @Test("Resuming waits for the pause's segment to land first")
    func resumeWaitsForThePause() async {
        let directory = scratch()
        let writer = GatedWriter(url: directory.appendingPathComponent("segment-0.mp4"))
        let engine = await primed(writer, in: directory)

        async let paused: Void? = try? await engine.pause()
        await writer.waitUntilFinishing()
        async let resumed: Void? = try? await engine.resume()
        await writer.releaseFinish()
        _ = await paused
        _ = await resumed

        let segments = await engine.segmentsForTesting
        #expect(segments.count == 1, "the pause's segment was lost or duplicated")
        #expect(segments.first?.lastPathComponent == "segment-0.mp4")
    }

    // MARK: - The stop trim

    /// The trim reaches the writer, and the duration the manifest is built from is the
    /// length of the file rather than of what was captured (docs/03 §1.8).
    @Test("A stop that trims travel shortens the file and what is reported")
    func stopTrimsTheTail() async throws {
        let directory = scratch()
        let writer = GatedWriter(url: directory.appendingPathComponent("segment-0.mp4"), length: 12)
        await writer.releaseFinish()
        let engine = await primed(writer, in: directory)

        let result = try await engine.stop(
            savingTo: directory.appendingPathComponent("out.mp4"),
            trimmingTail: 1.5
        )

        #expect(await writer.trimmed == 1.5)
        #expect(abs(result.duration - 10.5) < 0.0001)
    }

    /// A pause closes a segment too, and the seconds before a pause are recording.
    @Test("Pausing trims nothing")
    func pauseTrimsNothing() async throws {
        let directory = scratch()
        let writer = GatedWriter(url: directory.appendingPathComponent("segment-0.mp4"), length: 12)
        await writer.releaseFinish()
        let engine = await primed(writer, in: directory)

        try await engine.pause()

        #expect(await writer.trimmed == 0)
    }

    @Test("A stop with no travel writes everything that was captured")
    func hotkeyStopKeepsEverything() async throws {
        let directory = scratch()
        let writer = GatedWriter(url: directory.appendingPathComponent("segment-0.mp4"), length: 8)
        await writer.releaseFinish()
        let engine = await primed(writer, in: directory)

        let result = try await engine.stop(savingTo: directory.appendingPathComponent("out.mp4"))

        #expect(await writer.trimmed == 0)
        #expect(abs(result.duration - 8) < 0.0001)
    }
}

/// Succeeds, and records what it was asked to join.
private struct StubOverlapStitcher: SegmentStitching {
    func stitch(_ segments: [URL], to destination: URL) async throws -> URL {
        guard !segments.isEmpty else { throw RecordingError.noFramesCaptured }
        try Data("stitched".utf8).write(to: destination)
        return destination
    }
}
