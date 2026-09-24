import AVFoundation
import CoreMedia
import Foundation
import os
import ScreenCaptureKit
import Shared

/// Starting, pausing, resuming, stopping and cancelling (docs/04 §4.3, docs/11 S0.3).
///
/// Split out of the engine because the file outgrew its length budget once these methods
/// gained the generation counter and the serialised segment close — but it earns its own
/// file for a better reason than that. Every defect docs/11 found here was a race *between*
/// two of these methods rather than a fault inside any one of them: Pause colliding with
/// Stop, Cancel landing inside a suspended Start. They are worth reading side by side,
/// which is exactly what makes the overlaps visible.
extension RecordingEngine {
    // MARK: - Lifecycle

    func beginGeneration() -> Int {
        generation &+= 1
        return generation
    }

    /// Throws if this start was cancelled while it was suspended.
    func checkAlive(_ token: Int) throws {
        guard generation == token else { throw RecordingError.cancelledDuringStart }
    }

    /// Starts recording. The first segment begins immediately.
    public func start(target: RecordingTarget, options: RecordingOptions) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        // Claimed before the first suspension, so a second start cannot slip in behind it.
        state = .starting
        let token = beginGeneration()
        self.options = options
        audioMeter = AudioMeter()

        do {
            let content = try await shareableContent()
            try checkAlive(token)
            let capture = try makeFilter(for: target, in: content)
            pixelSize = capture.pixelSize
            liveTarget = target

            // Everything for this recording lives in one directory, so a crash leaves an
            // obvious place to recover segments from.
            let directory = segmentRoot
                .appendingPathComponent(
                    "\(InterruptedRecordingStore.directoryPrefix)\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sessionDirectory = directory
            segments = []
            accumulatedDuration = 0
            interruptionReason = nil

            try await beginSegment()
            try await startStream(filter: capture.filter, sourceRect: capture.sourceRect)
            try checkAlive(token)
            beginActivity()
            state = .recording
            let size = "\(pixelSize.width)×\(pixelSize.height)"
            logger.info("Recording started at \(size, privacy: .public)")
        } catch {
            // Whatever got built before this failed — or before it was cancelled — is torn
            // down here rather than left for the next start to trip over.
            await teardown()
            if state == .starting {
                state = .idle
            }
            throw error
        }
    }

    /// Pauses by closing the current segment (docs/04 §4.3).
    ///
    /// The stream keeps running but its frames are discarded, so resuming does not pay to
    /// rebuild it — and the closed segment is already a playable file.
    public func pause() async throws {
        guard state == .recording else { throw RecordingError.notRecording }
        state = .paused
        await closeSegment()
    }

    public func resume() async throws {
        guard state == .paused else { throw RecordingError.notRecording }
        // The pause that got us here may still be finalising its segment. Beginning the
        // next one first would let the two race to append to `segments`, and the recording
        // would stitch back together out of order.
        await awaitPendingClose()
        try await beginSegment()
        state = .recording
    }

    /// Stops and returns the finished file.
    /// - Parameter trimmingTail: seconds to drop from the end, for a stop the user walked
    ///   to (docs/03 §1.8). Zero for a hotkey, automation, or a recording that ended itself.
    public func stop(
        savingTo destination: URL,
        interruption: String? = nil,
        trimmingTail: TimeInterval = 0
    ) async throws -> RecordingResult {
        guard state == .recording || state == .paused else { throw RecordingError.notRecording }
        state = .finishing
        if let interruption {
            interruptionReason = interruption
        }

        // Whatever happens below, the engine comes back to `.idle`. Leaving it in
        // `.finishing` is what made a single failed stitch brick recording until relaunch:
        // the menu bar reads "not recording" while every later start throws (docs/07 C3).
        defer {
            endActivity()
            state = .idle
        }

        await closeSegment(trimmingTail: trimmingTail)
        await stopStream()

        guard !segments.isEmpty else {
            cleanUp()
            throw RecordingError.noFramesCaptured
        }

        do {
            let url = try await stitcher.stitch(segments, to: destination)
            let result = RecordingResult(
                fileURL: url,
                duration: accumulatedDuration,
                pixelSize: pixelSize,
                options: options,
                interruption: interruptionReason
            )
            cleanUp()
            return result
        } catch {
            // Keep the footage. Segments are finalised and individually playable by
            // design (docs/04 §4.3), so a failed join costs the user a join — not their
            // recording. The directory is surfaced rather than deleted.
            let directory = sessionDirectory
            logger.error("Stitch failed: \(error.localizedDescription, privacy: .public)")
            releaseSession(deletingFiles: false)
            throw RecordingError.stitchFailed(
                reason: error.localizedDescription,
                segmentDirectory: directory?.path
            )
        }
    }

    /// Abandons the recording and deletes what it wrote.
    public func cancel() async {
        // Retires the generation first, so a start still suspended in ScreenCaptureKit
        // finds out that the recording it is setting up no longer exists.
        generation &+= 1
        await awaitPendingClose()
        await teardown()
        endActivity()
        state = .idle
        logger.info("Recording cancelled")
    }

    /// Lets go of everything a running or half-started recording holds.
    func teardown() async {
        await writer?.cancel()
        writer = nil
        await stopStream()
        for segment in segments {
            try? FileManager.default.removeItem(at: segment)
        }
        cleanUp()
    }

    // MARK: - Segments

    func beginSegment() async throws {
        guard let sessionDirectory else { throw RecordingError.notRecording }
        // Each segment carries its own timeline; overlay timing counts from the whole
        // recording, so the segment's origin is reset and the accumulated duration added.
        segmentStartTime = nil
        let url = sessionDirectory.appendingPathComponent("segment-\(segments.count).mp4")
        writer = try makeWriter(url, pixelSize.width, pixelSize.height, options)
        // The held frame is not appended here. It still carries its pre-pause time, and a
        // segment that opened on it would write the whole pause back in as a frozen frame
        // (docs/17 T-REC-1). `consume` seeds it, re-timed, with the first live sample.
        segmentHasVideo = false
    }

    /// - Parameter trimmingTail: only a stop passes one. A pause closes a segment too, and
    ///   the seconds before a pause are recording, not travel.
    func closeSegment(trimmingTail: TimeInterval = 0) async {
        await awaitPendingClose()
        guard let writer else { return }
        self.writer = nil
        let close = Task { await self.drain(writer, trimmingTail: trimmingTail) }
        segmentClose = close
        await close.value
        segmentClose = nil
    }

    /// Waits for a close another caller started, so this one sees its result.
    func awaitPendingClose() async {
        guard let pending = segmentClose else { return }
        await pending.value
        segmentClose = nil
    }

    func drain(_ writer: any SegmentWriting, trimmingTail: TimeInterval = 0) async {
        if interruptionReason == nil, let reason = await writer.failureReason {
            interruptionReason = reason
        }
        let url = await writer.finish(trimmingTail: trimmingTail)
        // Asked *after* finishing, because the trim is decided there: the duration that
        // goes into the manifest has to be the length of the file, not of what was captured.
        accumulatedDuration += await writer.duration
        if let url {
            segments.append(url)
        }
    }

    func cleanUp() {
        releaseSession(deletingFiles: true)
    }

    /// Lets go of the session.
    ///
    /// - Parameter deletingFiles: false leaves the segments on disk, which is what a
    ///   failed stitch needs — the engine is finished with them, the user is not.
    func releaseSession(deletingFiles: Bool) {
        consumeTask?.cancel()
        consumeTask = nil
        output = nil
        audioMeter = AudioMeter()
        segments = []
        interruptionReason = nil
        lastVideoBox = nil
        liveTarget = nil
        segmentHasVideo = false
        endActivity()
        if deletingFiles, let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        sessionDirectory = nil
    }
}
