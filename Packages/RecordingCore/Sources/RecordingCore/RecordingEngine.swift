import AVFoundation
import CoreMedia
import Foundation
import os
import ScreenCaptureKit
import Shared

/// Screen recording (docs/04 §4.3, docs/03 §1.8).
///
/// The shape of this pipeline is dictated by one constraint: ScreenCaptureKit delivers
/// frames on its own queue, in real time, and will not wait. So the delegate is a
/// `nonisolated` fast path that does nothing but forward buffers into an `AsyncStream`,
/// and the actor consumes that stream and writes. Nothing expensive happens on SCK's
/// queue, and back-pressure is handled where it belongs — at the writer.
public actor RecordingEngine {
    /// How many sample buffers may queue between ScreenCaptureKit and the writer.
    ///
    /// Shallow on purpose: each one holds an IOSurface charged partly to WindowServer, so
    /// an unbounded queue turns a moment of compositing lag into hundreds of megabytes of
    /// retained frames (docs/07 H6).
    static let sampleBufferDepth = 3

    let logger = KadrLog.logger(.recording)
    private let signposter = KadrLog.signposter(.recording)
    let stitcher: any SegmentStitching
    let compositor = FrameCompositor()

    private var stream: SCStream?
    var output: StreamOutput?
    var writer: (any SegmentWriting)?
    let makeWriter: SegmentWriterFactory
    var consumeTask: Task<Void, Never>?

    /// Which recording the engine is currently setting up or running.
    ///
    /// Starting takes several hundred milliseconds of ScreenCaptureKit, and an actor runs
    /// other work across every suspension in it — so a `cancel()` could delete the session
    /// out from under a start that was still in flight, and the start would then resume
    /// and announce `.recording` over the top of it. The result was a recording that
    /// existed only in the menu bar: `state == .recording`, `writer == nil`, every frame
    /// dropped, desktop icons still hidden, and Stop reporting `noFramesCaptured`
    /// (docs/11 S0.3).
    ///
    /// A generation is the smallest thing that tells a resuming start "the recording you
    /// were setting up is gone". `cancel` bumps it; `start` checks it after every await.
    var generation = 0

    /// The close that is currently in flight, if any (docs/11 S0.3).
    ///
    /// `closeSegment` suspends twice, and an actor is free to run other work across a
    /// suspension — so Pause-then-Stop inside `finishWriting`'s 100–300 ms window used to
    /// re-enter it with the same writer still in the field. The segment's length was added
    /// to `accumulatedDuration` twice, and the inflated figure went into
    /// `CaptureManifest.duration` verbatim, so the studio timeline was longer than the
    /// footage and the playhead scrubbed into nothing.
    ///
    /// The writer now leaves the field before the first suspension and the second caller
    /// waits for the first rather than racing it. Waiting is the part that matters: Stop
    /// must not stitch a `segments` array that Pause has not finished appending to.
    var segmentClose: Task<Void, Never>?

    var options = RecordingOptions()
    var pixelSize = PixelSize(width: 0, height: 0)
    var segments: [URL] = []
    var sessionDirectory: URL?
    var accumulatedDuration: TimeInterval = 0
    var segmentStartTime: CMTime?

    /// Supplies click halos, keystrokes and the webcam picture, frame by frame.
    ///
    /// Optional because a recording with no overlays should not pay for the machinery,
    /// and because the monitors that feed it belong to the app, not to the pipeline.
    private var overlayProvider: (any RecordingOverlayProviding)?

    /// Setter is module-internal rather than file-private: the lifecycle that drives this
    /// state machine lives in `RecordingEngine+Lifecycle.swift`, and a module is the right
    /// granularity for it — nothing outside `RecordingCore` can move a recording's state.
    public internal(set) var state: RecordingState = .idle

    /// Window numbers to leave out of display and region recordings (docs/10 R3.2).
    public private(set) var excludedWindowIDs: Set<CGWindowID> = []

    public init(stitcher: any SegmentStitching = SegmentStitcher()) {
        self.stitcher = stitcher
        makeWriter = { fileURL, pixelWidth, pixelHeight, options in
            try SegmentWriter(
                fileURL: fileURL,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                options: options
            )
        }
    }

    #if DEBUG
        /// Builds an engine whose segments are written by something the caller controls.
        ///
        /// The label is required, so this cannot be reached by accident from the public
        /// initialiser (docs/11 S1).
        init(stitcher: any SegmentStitching = SegmentStitcher(), makeWriter: @escaping SegmentWriterFactory) {
            self.stitcher = stitcher
            self.makeWriter = makeWriter
        }
    #endif

    public func setExcludedWindowIDs(_ ids: Set<CGWindowID>) {
        excludedWindowIDs = ids
    }

    #if DEBUG
        /// Puts the engine into the state a running recording leaves it in.
        ///
        /// A test seam, and a deliberate one: everything upstream of `stop` needs
        /// ScreenCaptureKit and a real display, which CI has neither of — but the state
        /// machine `stop` drives is exactly where the review found a recording could brick
        /// (docs/07 C3). Debug-only, so it cannot exist in a shipped build.
        func primeForTesting(
            state: RecordingState,
            segments: [URL],
            sessionDirectory: URL?,
            writer: (any SegmentWriting)? = nil
        ) {
            self.state = state
            self.segments = segments
            self.sessionDirectory = sessionDirectory
            self.writer = writer
            accumulatedDuration = writer == nil ? 1 : 0
            pixelSize = PixelSize(width: 100, height: 100)
        }

        /// What `start` claims before its first suspension.
        func beginStartForTesting() -> Int {
            state = .starting
            return beginGeneration()
        }

        /// What `start` does when it resumes from that suspension.
        ///
        /// `start` itself cannot run in CI — it needs a display and a TCC grant — but the
        /// race S0.3 closes is entirely about what happens on the way *back*, so this is
        /// the resumption with the same generation check the real one performs.
        func finishStartForTesting(token: Int) throws {
            try checkAlive(token)
            state = .recording
        }

        var accumulatedDurationForTesting: TimeInterval {
            accumulatedDuration
        }

        var segmentsForTesting: [URL] {
            segments
        }
    #endif

    /// Watches the recording's own clock (docs/10 R0.1).
    ///
    /// Its own channel rather than a side effect of drawing overlays. The clock was
    /// previously published only to the overlay provider, and the coordinator installs one
    /// of those only when the user has asked for a halo or a keystroke caption — so a
    /// studio capture, which is exactly the case that wants no overlays, received no clock
    /// at all. Every event in the sidecar was stamped zero, the sample-rate gate compared
    /// zero against zero and refused everything after the first, and the flagship shipped
    /// inert.
    ///
    /// Called on every composited frame with pauses already removed, so a caller can stamp
    /// an event against the footage without knowing what a pause is.
    public func setClockObserver(_ observer: (@Sendable (TimeInterval) -> Void)?) {
        clockObserver = observer
    }

    private var clockObserver: (@Sendable (TimeInterval) -> Void)?

    /// Sets what gets drawn into frames. Nil turns overlays off entirely.
    public func setOverlayProvider(_ provider: (any RecordingOverlayProviding)?) {
        overlayProvider = provider
    }

    var geometryObserver: (@Sendable (CGRect, CGFloat, TimeInterval) -> Void)?
    var lastContentRect: CGRect?
    var pointPixelScale: CGFloat = 2

    /// How far a window has to move before it counts as having moved.
    ///
    /// SCK's content rect jitters by fractions of a point between otherwise identical
    /// frames, and reporting that would turn "the window moved twice" into a geometry
    /// sample per frame — which is the cost this design exists to avoid.
    static let geometryTolerance: CGFloat = 0.5

    // MARK: - Stream

    func startStream(filter: SCContentFilter, sourceRect: CGRect?) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        if let sourceRect {
            // Without this a region recording captures the whole display and squeezes it
            // into the region's size. `sourceRect` is display-local points, which is why
            // the rect is rebased in `makeFilter` rather than passed through global.
            configuration.sourceRect = sourceRect
            configuration.destinationRect = CGRect(
                x: 0,
                y: 0,
                width: CGFloat(pixelSize.width),
                height: CGFloat(pixelSize.height)
            )
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate.rawValue))
        configuration.showsCursor = options.showsCursor
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = options.excludesOwnAudio
        if options.capturesMicrophone, #available(macOS 15.0, *) {
            // ScreenCaptureKit records the mic alongside the screen, so there is no
            // second capture session to keep in sync (docs/03 §1.8, docs/04 §4.3).
            configuration.captureMicrophone = true
        }
        // IOSurface-backed buffers straight from SCK's pool; the default depth of 3 is
        // deliberate — each retained frame is a full surface charged partly to
        // WindowServer, and raising it without measurement is how recordings start
        // costing hundreds of megabytes (docs/04 §4.3).
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        if options.recordsHDR, #available(macOS 15.0, *) {
            // Ten bits per channel, and the display's own range rather than a canonical
            // one — a screen recording should look like the screen (docs/04 §4.3).
            configuration.captureDynamicRange = .hdrLocalDisplay
            configuration.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
            configuration.colorSpaceName = CGColorSpace.itur_2100_HLG
        }

        let (stream, output) = try makeStream(filter: filter, configuration: configuration)
        self.stream = stream
        self.output = output

        consumeTask = Task { [weak self] in
            for await box in output.buffers {
                await self?.consume(box)
            }
        }

        do {
            try await stream.startCapture()
        } catch {
            throw RecordingError.writingFailed(error.localizedDescription)
        }
    }

    private func makeStream(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) throws -> (SCStream, StreamOutput) {
        let output = StreamOutput()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            if options.capturesSystemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            }
            // Without this output the writer's microphone track exists and is never fed,
            // which is how the toggle produced silent narration files (docs/07 H2).
            if options.capturesMicrophone, #available(macOS 15.0, *) {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
            }
        } catch {
            throw RecordingError.writingFailed(error.localizedDescription)
        }
        return (stream, output)
    }

    func stopStream() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        output?.finish()
        consumeTask?.cancel()
        consumeTask = nil
    }

    /// Draws any overlays into the frame, then writes it.
    ///
    /// The compositing happens here, between SCK and the writer, which is what puts the
    /// click halos and keystrokes in the file and nowhere else (docs/04 §4.3).
    private func consume(_ box: SampleBufferBox) async {
        guard state == .recording, let writer else { return }

        if box.kind == .video {
            let time = recordingTime(of: box.buffer)
            reportGeometry(of: box, at: time)
            // Published before the overlay is drawn, and whether or not one is drawn. The
            // clock is the recording's own account of where it is; anything that wants to
            // stamp an event against the footage needs it, and the sidecar needs it most
            // when the user has asked for no overlays at all.
            clockObserver?(time)
            if let overlayProvider {
                composite(overlayProvider, into: box.buffer, at: time)
            }
        }
        await writer.append(box)
    }

    /// Where this frame sits in the recording, pauses already taken out.
    ///
    /// One definition, used by the overlays, the geometry samples and the sidecar — which
    /// is the point. Three callers deriving "how far in are we" separately is three chances
    /// to disagree about what a pause did.
    private func recordingTime(of buffer: CMSampleBuffer) -> TimeInterval {
        let presentation = CMSampleBufferGetPresentationTimeStamp(buffer)
        if segmentStartTime == nil {
            segmentStartTime = presentation
        }
        let elapsed = segmentStartTime.map {
            CMTimeGetSeconds(CMTimeSubtract(presentation, $0))
        } ?? 0
        return accumulatedDuration + elapsed
    }

    private func composite(
        _ provider: any RecordingOverlayProviding,
        into buffer: CMSampleBuffer,
        at time: TimeInterval
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
        compositor.draw(provider.overlay(atRecordingTime: time), into: pixelBuffer)
    }
}

/// The `nonisolated` fast path off ScreenCaptureKit's delegate queue (docs/04 §4.3).
///
/// It does one thing: forward the buffer. Anything more here — encoding, allocation, a
/// hop to an actor — would block SCK's queue and drop frames.
final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.kadr.recording.samples", qos: .userInitiated)
    /// Last rect the geometry probe logged, so it reports moves rather than frames.
    private var lastProbedRect: CGRect?
    private let continuation: AsyncStream<SampleBufferBox>.Continuation
    let buffers: AsyncStream<SampleBufferBox>
    let logger = KadrLog.logger(.recording)

    override init() {
        // `makeStream` hands back the stream and its continuation together, which avoids
        // the implicitly-unwrapped dance the closure form of `AsyncStream` requires.
        //
        // Bounded, and deliberately shallow: each buffer holds an IOSurface charged partly
        // to WindowServer, so an unbounded queue turns a moment of compositing lag into
        // hundreds of megabytes of retained frames. Dropping the oldest is right for a
        // recording — the writer stamps its own timestamps, so a dropped frame is a
        // dropped frame, not a desynchronised one (docs/07 H6).
        let (stream, continuation) = AsyncStream<SampleBufferBox>.makeStream(
            bufferingPolicy: .bufferingNewest(RecordingEngine.sampleBufferDepth)
        )
        buffers = stream
        self.continuation = continuation
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // SCK only sends a frame when something changed, and marks the rest. Anything
            // that is not a complete frame is not a picture.
            guard isComplete(sampleBuffer) else { return }
            continuation.yield(SampleBufferBox(
                buffer: sampleBuffer,
                kind: .video,
                contentRect: contentRect(sampleBuffer)
            ))
        case .audio:
            continuation.yield(SampleBufferBox(buffer: sampleBuffer, kind: .systemAudio))
        default:
            // `.microphone` is macOS 15+, so it cannot be matched in a `case` that has to
            // compile against the 14 SDK floor (docs/04 §4.3).
            if #available(macOS 15.0, *), type == .microphone {
                continuation.yield(SampleBufferBox(buffer: sampleBuffer, kind: .microphone))
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("Recording stream stopped: \(error.localizedDescription, privacy: .public)")
        continuation.finish()
    }

    func finish() {
        continuation.finish()
    }

    /// Where the captured content was on screen for this frame.
    ///
    /// A window recording's content moves when the window does, and this attachment is the
    /// only account of where it went. Read here, on the frame it belongs to, because that
    /// is the only place the two are known to correspond.
    func contentRect(_ buffer: CMSampleBuffer) -> CGRect? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let first = attachments.first,
            let raw = first[.contentRect] as? [String: Any]
        else {
            return nil
        }
        guard let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
        logGeometryAttachments(first, contentRect: rect)
        return rect
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
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
