import AVFoundation
import CoreMedia
import Foundation
import os
import Shared

/// A `CMSampleBuffer` on its way from ScreenCaptureKit's delegate queue to the writer.
///
/// `CMSampleBuffer` is a CoreMedia reference type with no `Sendable` conformance, and it
/// has to cross from SCK's callback queue into the writer actor. Doc 04 §8 sanctions this
/// wrapper for exactly that, under a documented invariant: **single consumer**. Each
/// buffer is produced once, handed over once, and read by one writer. Nothing else
/// retains or mutates it.
public struct SampleBufferBox: @unchecked Sendable {
    public let buffer: CMSampleBuffer
    public let kind: Kind
    public let contentRect: CGRect?
    public let screenRect: CGRect?
    public let scaleFactor: CGFloat?

    public init(
        buffer: CMSampleBuffer,
        kind: Kind,
        contentRect: CGRect? = nil,
        screenRect: CGRect? = nil,
        scaleFactor: CGFloat? = nil
    ) {
        self.buffer = buffer
        self.kind = kind
        self.contentRect = contentRect
        self.screenRect = screenRect
        self.scaleFactor = scaleFactor
    }

    /// The same sample stamped at `time`, sharing its image; nil if CoreMedia refuses.
    ///
    /// Used to reuse a held frame after a pause without carrying its old timestamp.
    func retimed(to time: CMTime) -> SampleBufferBox? {
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else { return nil }
        return SampleBufferBox(
            buffer: copy,
            kind: kind,
            contentRect: contentRect,
            screenRect: screenRect,
            scaleFactor: scaleFactor
        )
    }

    public enum Kind: Sendable {
        case video
        case systemAudio
        case microphone
        case clock
    }
}

/// What `RecordingEngine` needs from the thing that writes a segment.
///
/// A protocol so the engine's state machine can be tested without a display, a TCC grant
/// or an encoder (docs/11 S1). Every race S0.3 closes lives inside the window where
/// `finish()` is suspended — in production that is 100–300 ms of `AVAssetWriter` and
/// unobservable from a test, so a fake whose `finish()` the test decides when to complete
/// turns the window from the thing that makes the bug unreproducible into the thing the
/// test is about.
protocol SegmentWriting: Actor {
    /// The wall-clock length written so far.
    var duration: TimeInterval { get }
    /// Why writing stopped, once the encoder has failed (docs/16 REC-2).
    var failureReason: String? { get }
    @discardableResult
    func append(_ box: SampleBufferBox) -> Bool
    /// Finishes the file, dropping `tail` seconds from its end (docs/03 §1.8).
    func finish(trimmingTail tail: TimeInterval) async -> URL?
    func cancel() async
}

/// Makes the writer for one segment. Injected so tests can supply a fake.
typealias SegmentWriterFactory = @Sendable (
    _ fileURL: URL,
    _ pixelWidth: Int,
    _ pixelHeight: Int,
    _ options: RecordingOptions
) throws -> any SegmentWriting

/// Writes one continuous stretch of recording to one file.
///
/// Recordings are made of segments, one per pause/resume span. That is what makes
/// pause/resume gapless *and* crash-safe: every segment is finalised as it ends, so a
/// process that dies mid-recording leaves playable files behind rather than a truncated
/// one (docs/03 §1.8 accept list).
actor SegmentWriter: SegmentWriting {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let logger = KadrLog.logger(.recording)

    let fileURL: URL
    private var hasStartedSession = false
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private(set) var isFinished = false
    private(set) var failureReason: String?

    init(
        fileURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        options: RecordingOptions
    ) throws {
        self.fileURL = fileURL
        do {
            writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        } catch {
            throw RecordingError.couldNotCreateWriter(error.localizedDescription)
        }

        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: options.videoSettings(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        )
        // Without this the writer buffers rather than encoding as it goes, and a long
        // recording turns into a memory problem.
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecordingError.couldNotCreateWriter("the writer refused a video input")
        }
        writer.add(videoInput)

        if options.capturesSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: options.audioSettings())
            input.expectsMediaDataInRealTime = true
            audioInput = writer.canAdd(input) ? input : nil
            audioInput.map(writer.add)
        } else {
            audioInput = nil
        }

        if options.capturesMicrophone {
            // A separate track, so the user can drop the narration later without
            // re-recording (docs/03 §1.8).
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: options.audioSettings())
            input.expectsMediaDataInRealTime = true
            microphoneInput = writer.canAdd(input) ? input : nil
            microphoneInput.map(writer.add)
        } else {
            microphoneInput = nil
        }

        // Fragments so a crash mid-segment still leaves a playable file (docs/03 §1.8).
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        guard writer.startWriting() else {
            throw RecordingError.couldNotCreateWriter(writer.error?.localizedDescription ?? "unknown")
        }
    }

    /// Appends one sample. Returns false when the sample was dropped.
    @discardableResult
    func append(_ box: SampleBufferBox) -> Bool {
        if writer.status == .failed {
            noteFailure()
            return false
        }
        guard !isFinished, writer.status == .writing else { return false }
        let buffer = box.buffer
        guard CMSampleBufferDataIsReady(buffer) else { return false }
        guard beginSessionIfNeeded(for: box, at: CMSampleBufferGetPresentationTimeStamp(buffer)) else {
            return false
        }
        if box.kind == .clock {
            return true
        }
        let input: AVAssetWriterInput? = switch box.kind {
        case .video: videoInput
        case .systemAudio: audioInput
        case .microphone: microphoneInput
        case .clock: nil
        }
        // Back-pressure: the encoder tells us when it cannot keep up, and dropping a
        // frame is better than growing an unbounded queue (docs/04 §4.3).
        guard let input, input.isReadyForMoreMediaData else { return false }
        return input.append(buffer)
    }

    private func beginSessionIfNeeded(for box: SampleBufferBox, at time: CMTime) -> Bool {
        if !hasStartedSession {
            // Only video starts the session: an audio sample arriving first would set the
            // origin before there is a picture, and the file would open with silence.
            guard box.kind == .video else { return false }
            writer.startSession(atSourceTime: time)
            hasStartedSession = true
            firstPresentationTime = time
        }
        lastPresentationTime = time
        return true
    }

    /// The wall-clock length written so far, less anything trimmed from its end.
    ///
    /// Read after `finish`, so what the engine accumulates is the length of the file that
    /// exists rather than the length of what was captured — the two differ by the trim, and
    /// a manifest that disagrees with its movie puts every zoom in the studio out by it.
    var duration: TimeInterval {
        guard let first = firstPresentationTime, let last = lastPresentationTime else { return 0 }
        let written = CMTimeGetSeconds(CMTimeSubtract(last, first))
        return max(written - trimmedTail, 0)
    }

    /// Finishes the file.
    ///
    /// Reentrancy-safe, and it genuinely was not before: it set `isFinished` on the way in
    /// and then suspended for the 100–300 ms `finishWriting` takes, so a second caller in
    /// that window was handed `fileURL` for a file still being written and went off to
    /// stitch it (docs/11 S0.3). A second caller now waits for the first and gets the same
    /// answer, which is what "safe to call twice" was always supposed to mean.
    func finish(trimmingTail tail: TimeInterval = 0) async -> URL? {
        if let finishing {
            return await finishing.value
        }
        guard !isFinished else { return nil }
        isFinished = true
        trimmedTail = max(tail, 0)
        let finishing = Task { await self.finishWriting() }
        self.finishing = finishing
        return await finishing.value
    }

    /// Seconds cut from the end of this segment, decided at `finish`.
    private var trimmedTail: TimeInterval = 0

    private var finishing: Task<URL?, Never>?

    private func finishWriting() async -> URL? {
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        microphoneInput?.markAsFinished()

        guard hasStartedSession else {
            // Nothing was ever written; leave no empty file behind.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        endSessionForTrim()
        await writer.finishWriting()
        if writer.status == .failed {
            noteFailure()
            logger.error("Segment failed: \(self.writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            // Keep a started file: fragments already on disk are playable, and deleting
            // them here is how a full disk used to throw the whole take away (docs/16 REC-2).
            if hasStartedSession, FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
            return nil
        }
        return fileURL
    }

    /// Ends the writing session early, which is what drops the tail.
    ///
    /// `AVAssetWriter` writes up to the session's end time: samples already appended past
    /// it are not in the finished file. Doing it here, once, rather than refusing appends
    /// as they arrive, is what keeps the trim off the sample path — the decision is only
    /// known at stop, and the encoder must not grow a branch for it.
    ///
    /// Both tracks end at the same source time, so audio and video stay in step: trimming
    /// them separately is how a cut ends with a quarter second of sound over a still frame.
    private func endSessionForTrim() {
        guard trimmedTail > 0, let first = firstPresentationTime, let last = lastPresentationTime else {
            return
        }
        let cut = CMTimeSubtract(last, CMTime(seconds: trimmedTail, preferredTimescale: 600))
        guard CMTimeCompare(cut, first) > 0 else { return }
        writer.endSession(atSourceTime: cut)
    }

    private func noteFailure() {
        guard failureReason == nil else { return }
        failureReason = writer.error?.localizedDescription ?? "The recording writer failed."
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: fileURL)
    }
}
