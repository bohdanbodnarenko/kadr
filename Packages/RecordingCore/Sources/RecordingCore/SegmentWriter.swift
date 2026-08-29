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
struct SampleBufferBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
    let kind: Kind
    /// Where the recorded content sat on screen when this frame was taken, from SCK's own
    /// per-frame attachment (docs/09 U3.1).
    ///
    /// Carried on the frame rather than asked for separately, because it is only true *of*
    /// a frame: a window that moves mid-recording has a different answer for every one, and
    /// a rect read a moment later describes a moment the footage does not show.
    let contentRect: CGRect?

    init(buffer: CMSampleBuffer, kind: Kind, contentRect: CGRect? = nil) {
        self.buffer = buffer
        self.kind = kind
        self.contentRect = contentRect
    }

    enum Kind: Sendable {
        case video
        case systemAudio
        case microphone
    }
}

/// Writes one continuous stretch of recording to one file.
///
/// Recordings are made of segments, one per pause/resume span. That is what makes
/// pause/resume gapless *and* crash-safe: every segment is finalised as it ends, so a
/// process that dies mid-recording leaves playable files behind rather than a truncated
/// one (docs/03 §1.8 accept list).
actor SegmentWriter {
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

        guard writer.startWriting() else {
            throw RecordingError.couldNotCreateWriter(writer.error?.localizedDescription ?? "unknown")
        }
    }

    /// Appends one sample. Returns false when the sample was dropped.
    @discardableResult
    func append(_ box: SampleBufferBox) -> Bool {
        guard !isFinished, writer.status == .writing else { return false }
        let buffer = box.buffer
        guard CMSampleBufferDataIsReady(buffer) else { return false }

        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if !hasStartedSession {
            // Only video starts the session: an audio sample arriving first would set the
            // origin before there is a picture, and the file would open with silence.
            guard box.kind == .video else { return false }
            writer.startSession(atSourceTime: time)
            hasStartedSession = true
            firstPresentationTime = time
        }
        lastPresentationTime = time

        let input: AVAssetWriterInput? = switch box.kind {
        case .video: videoInput
        case .systemAudio: audioInput
        case .microphone: microphoneInput
        }
        // Back-pressure: the encoder tells us when it cannot keep up, and dropping a
        // frame is better than growing an unbounded queue (docs/04 §4.3).
        guard let input, input.isReadyForMoreMediaData else { return false }
        return input.append(buffer)
    }

    /// The wall-clock length written so far.
    var duration: TimeInterval {
        guard let first = firstPresentationTime, let last = lastPresentationTime else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(last, first))
    }

    /// Finishes the file. Safe to call twice.
    func finish() async -> URL? {
        guard !isFinished else { return fileURL }
        isFinished = true

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        microphoneInput?.markAsFinished()

        guard hasStartedSession else {
            // Nothing was ever written; leave no empty file behind.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        await writer.finishWriting()
        if writer.status == .failed {
            logger.error("Segment failed: \(self.writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return fileURL
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: fileURL)
    }
}
