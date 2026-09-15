import AVFoundation
import CoreMedia
import Foundation
import os
import ScreenCaptureKit
import Shared

/// The `nonisolated` fast path off ScreenCaptureKit's delegate queue (docs/04 §4.3).
///
/// It does one thing: forward the buffer. Anything more here — encoding, allocation, a
/// hop to an actor — would block SCK's queue and drop frames.
final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.kadr.recording.samples", qos: .userInitiated)
    let audioQueue = DispatchQueue(label: "app.kadr.recording.audio", qos: .userInitiated)
    /// Last rect the geometry probe logged, so it reports moves rather than frames.
    private var lastProbedRect: CGRect?
    private let videoContinuation: AsyncStream<SampleBufferBox>.Continuation
    private let audioContinuation: AsyncStream<SampleBufferBox>.Continuation
    private let microphoneContinuation: AsyncStream<SampleBufferBox>.Continuation
    private let events: AsyncStream<RecordingEngineEvent>.Continuation
    let video: AsyncStream<SampleBufferBox>
    let audio: AsyncStream<SampleBufferBox>
    /// Mic samples for the teleprompter, drop-oldest so a slow follower cannot stall SCK
    /// (docs/16 REC-19d).
    let microphone: AsyncStream<SampleBufferBox>
    let logger = KadrLog.logger(.recording)

    init(events: AsyncStream<RecordingEngineEvent>.Continuation) {
        let (videoStream, videoContinuation) = AsyncStream<SampleBufferBox>.makeStream(
            bufferingPolicy: .bufferingNewest(RecordingEngine.sampleBufferDepth)
        )
        let (audioStream, audioContinuation) = AsyncStream<SampleBufferBox>.makeStream(
            bufferingPolicy: .bufferingOldest(RecordingEngine.audioBufferDepth)
        )
        let (microphoneStream, microphoneContinuation) = AsyncStream<SampleBufferBox>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        video = videoStream
        audio = audioStream
        microphone = microphoneStream
        self.videoContinuation = videoContinuation
        self.audioContinuation = audioContinuation
        self.microphoneContinuation = microphoneContinuation
        self.events = events
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            let attachments = frameAttachments(sampleBuffer)
            if isComplete(sampleBuffer) {
                videoContinuation.yield(SampleBufferBox(
                    buffer: sampleBuffer,
                    kind: .video,
                    contentRect: contentRect(attachments),
                    screenRect: screenRect(attachments),
                    scaleFactor: scaleFactor(attachments)
                ))
            } else if isIdle(sampleBuffer) {
                videoContinuation.yield(SampleBufferBox(
                    buffer: sampleBuffer,
                    kind: .clock,
                    contentRect: contentRect(attachments),
                    screenRect: screenRect(attachments),
                    scaleFactor: scaleFactor(attachments)
                ))
            }
        case .audio:
            audioContinuation.yield(SampleBufferBox(buffer: sampleBuffer, kind: .systemAudio))
        default:
            if #available(macOS 15.0, *), type == .microphone {
                let box = SampleBufferBox(buffer: sampleBuffer, kind: .microphone)
                audioContinuation.yield(box)
                microphoneContinuation.yield(box)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("Recording stream stopped: \(error.localizedDescription, privacy: .public)")
        events.yield(.streamStopped(error.localizedDescription))
        videoContinuation.finish()
        audioContinuation.finish()
        microphoneContinuation.finish()
    }

    func finish() {
        videoContinuation.finish()
        audioContinuation.finish()
        microphoneContinuation.finish()
    }

    /// Where the captured content was on screen for this frame.
    ///
    /// A window recording's content moves when the window does, and this attachment is the
    /// only account of where it went. Read here, on the frame it belongs to, because that
    /// is the only place the two are known to correspond.
    func frameAttachments(_ buffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        else {
            return nil
        }
        return attachments.first
    }

    func contentRect(_ attachments: [SCStreamFrameInfo: Any]?) -> CGRect? {
        guard let raw = attachments?[.contentRect] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary)
        else {
            return nil
        }
        if let attachments {
            logGeometryAttachments(attachments, contentRect: rect)
        }
        return rect
    }

    func screenRect(_ attachments: [SCStreamFrameInfo: Any]?) -> CGRect? {
        guard let raw = attachments?[.screenRect] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: raw as CFDictionary)
    }

    func scaleFactor(_ attachments: [SCStreamFrameInfo: Any]?) -> CGFloat? {
        attachments?[.scaleFactor] as? CGFloat
    }

    /// Logs `.contentRect` beside `.screenRect`, to settle what the first one means
    /// (docs/11 S2).
    ///
    /// Apple documents `contentRect` as the content's rect *within the frame* — surface
    /// space — while `RecordingEngine+Geometry` and `MovingWindowConverter` both treat it
    /// as a rect on screen, and `MovingWindowConverter` does `contentRect.contains(point)`
    /// with a screen point. If Apple's semantics hold, a window recording's clicks are
    /// dropped by that `contains` and any survivors map to the wrong pixel.
    ///
    /// This cannot be settled by reading: `WindowSpaceTests` asserts the semantics the code
    /// intends rather than the ones ScreenCaptureKit has, so it agrees with the code
    /// whichever is right. It needs one recording of a window being dragged across the
    /// screen, on a real Mac, which no reviewer in this thread can run.
    ///
    /// **To settle it:** run a window recording, drag the window from one side of the
    /// display to the other, and read the log —
    /// `log stream --predicate 'subsystem == "app.kadr"' --info | grep geometry-probe`.
    /// If `content` stays near the origin while `screen` moves, `contentRect` is surface
    /// space: switch the two consumers to `.screenRect` (with a 14.0 fallback to
    /// `contentRect`) and rebuild the `WindowSpaceTests` fixtures around the real answer.
    /// If both move together, the current reading is right and this probe can go.
    ///
    /// Debug-only, and rate-limited to a move, so it cannot cost a shipping recording
    /// anything.
    private func logGeometryAttachments(_ attachments: [SCStreamFrameInfo: Any], contentRect: CGRect) {
        #if DEBUG
            guard RecordingEngine.hasMoved(from: lastProbedRect, to: contentRect) else { return }
            lastProbedRect = contentRect
            let screen = (attachments[.screenRect] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            let scale = (attachments[.scaleFactor] as? CGFloat) ?? 0
            logger.info(
                """
                geometry-probe content=\(String(describing: contentRect), privacy: .public) \
                screen=\(String(describing: screen), privacy: .public) \
                scale=\(scale, privacy: .public)
                """
            )
        #endif
    }

    /// Reads SCK's per-frame status out of the buffer's attachments.
    func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        status(of: buffer) == .complete
    }

    func isIdle(_ buffer: CMSampleBuffer) -> Bool {
        status(of: buffer) == .idle
    }

    func status(of buffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let raw = frameAttachments(buffer)?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }
}
