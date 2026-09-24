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
    static let audioBufferDepth = 256

    let logger = KadrLog.logger(.recording)
    private let signposter = KadrLog.signposter(.recording)
    let stitcher: any SegmentStitching
    let compositor = FrameCompositor()
    let segmentRoot: URL
    let activityAsserter: any RecordingActivityAsserting
    private var activitySession: (any RecordingActivitySession)?

    private var stream: SCStream?
    var output: StreamOutput?
    var writer: (any SegmentWriting)?
    let makeWriter: SegmentWriterFactory
    var consumeTask: Task<Void, Never>?
    let eventsContinuation: AsyncStream<RecordingEngineEvent>.Continuation
    /// Stream death and writer failure, consumed by the coordinator (docs/16 REC-1).
    public nonisolated let events: AsyncStream<RecordingEngineEvent>
    /// Why this take is ending early, if it is.
    var interruptionReason: String?

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
    /// Last-buffer loudness, sampled by the control bar (CleanShot §13.3).
    public internal(set) var audioMeter = AudioMeter()
    var pixelSize = PixelSize(width: 0, height: 0)
    var segments: [URL] = []
    var sessionDirectory: URL?
    /// The in-progress segment folder, for crash-recovery pairing (docs/16 REC-8).
    public var inProgressDirectory: URL? {
        sessionDirectory
    }

    /// Live microphone samples for the teleprompter (docs/16 REC-19d).
    public var microphoneTap: AsyncStream<SampleBufferBox> {
        output?.microphone ?? AsyncStream { $0.finish() }
    }

    var accumulatedDuration: TimeInterval = 0
    var segmentStartTime: CMTime?
    /// Last complete video frame, so a resume on a static screen still starts the writer
    /// and a static tail survives Stop (docs/16 REC-5).
    var lastVideoBox: SampleBufferBox?
    /// What the running stream records, so its filter can be rebuilt mid-take.
    var liveTarget: RecordingTarget?
    var segmentHasVideo = false

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

    public init(
        stitcher: any SegmentStitching = SegmentStitcher(),
        segmentRoot: URL = FileManager.default.temporaryDirectory,
        activity: any RecordingActivityAsserting = ProcessInfoRecordingActivity()
    ) {
        self.stitcher = stitcher
        self.segmentRoot = segmentRoot
        activityAsserter = activity
        makeWriter = { fileURL, pixelWidth, pixelHeight, options in
            try SegmentWriter(
                fileURL: fileURL,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                options: options
            )
        }
        let (stream, continuation) = AsyncStream<RecordingEngineEvent>.makeStream()
        events = stream
        eventsContinuation = continuation
    }

    #if DEBUG
        /// Builds an engine whose segments are written by something the caller controls.
        ///
        /// The label is required, so this cannot be reached by accident from the public
        /// initialiser (docs/11 S1).
        init(
            stitcher: any SegmentStitching = SegmentStitcher(),
            makeWriter: @escaping SegmentWriterFactory,
            segmentRoot: URL = FileManager.default.temporaryDirectory,
            activity: any RecordingActivityAsserting = ProcessInfoRecordingActivity()
        ) {
            self.stitcher = stitcher
            self.segmentRoot = segmentRoot
            activityAsserter = activity
            self.makeWriter = makeWriter
            let (stream, continuation) = AsyncStream<RecordingEngineEvent>.makeStream()
            events = stream
            eventsContinuation = continuation
        }
    #endif

    public func setExcludedWindowIDs(_ ids: Set<CGWindowID>) {
        excludedWindowIDs = ids
    }

    /// Changes which of Kadr's windows are left out of a recording that is already running.
    ///
    /// The filter used to be fixed when the stream started, so a panel created after that —
    /// the teleprompter is the one that matters — was recorded into the file (docs/17
    /// T-REC-7). A window recording is untouched: it never contained Kadr's windows.
    public func updateExcludedWindowIDs(_ ids: Set<CGWindowID>) async {
        guard ids != excludedWindowIDs else { return }
        excludedWindowIDs = ids
        guard let stream, let liveTarget else { return }
        if case .window = liveTarget {
            return
        }
        do {
            let content = try await shareableContent()
            // The recording may have ended while ScreenCaptureKit answered.
            guard self.stream === stream else { return }
            let setup = try makeFilter(for: liveTarget, in: content)
            try await stream.updateContentFilter(setup.filter)
        } catch {
            logger.error("Could not update the recording's exclusions: \(error.localizedDescription, privacy: .public)")
        }
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
            beginActivity()
        }

        /// Yields a stream-stopped event the way `SCStreamDelegate` would (docs/16 REC-1).
        func deliverStreamStopForTesting(_ message: String) {
            noteInterruption(.streamStopped(message))
            output?.finish()
        }

        /// Hands a sample to the engine as the stream's consumer would.
        func deliverForTesting(_ box: SampleBufferBox) async {
            await consume(box)
        }

        func deliverWriterFailureForTesting(_ message: String) {
            noteInterruption(.writerFailed(message))
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
            if let deviceID = options.microphoneDeviceID, !deviceID.isEmpty {
                configuration.microphoneCaptureDeviceID = deviceID
            }
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
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await box in output.video {
                        await self?.consume(box)
                    }
                }
                group.addTask { [weak self] in
                    for await box in output.audio {
                        await self?.consume(box)
                    }
                }
                await group.waitForAll()
            }
        }

        do {
            try await stream.startCapture()
        } catch {
            throw Self.startError(error, otherwise: RecordingError.writingFailed)
        }
    }

    private func makeStream(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) throws -> (SCStream, StreamOutput) {
        let output = StreamOutput(events: eventsContinuation)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            if options.capturesSystemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.audioQueue)
            }
            if options.capturesMicrophone, #available(macOS 15.0, *) {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.audioQueue)
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

        if box.kind == .clock {
            let time = recordingTime(of: box.buffer)
            reportGeometry(of: box, at: time)
            clockObserver?(time)
            await seedHeldFrame(into: writer, at: box)
            return
        }
        if box.kind != .video {
            // Audio can arrive before the first picture after a resume; the held frame
            // opens the segment so that sound is not dropped by a session with no video.
            await seedHeldFrame(into: writer, at: box)
        }
        if box.kind == .microphone {
            audioMeter.microphone = AudioLevel.peak(of: box.buffer)
        } else if box.kind == .systemAudio {
            audioMeter.system = AudioLevel.peak(of: box.buffer)
        }

        if box.kind == .video {
            lastVideoBox = box
            segmentHasVideo = true
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
        let accepted = await writer.append(box)
        if !accepted, box.kind == .video {
            // A frame the encoder refused, usually back-pressure. Visible in Instruments
            // next to the pool's queue depth, which is what tuning it needs (rule 8,
            // docs/17 T-REC-10).
            signposter.emitEvent("Dropped frame")
        }
        if !accepted, let reason = await writer.failureReason {
            noteInterruption(.writerFailed(reason))
        }
    }

    /// Opens a segment that has no picture yet with the last frame seen, re-timed to `box`.
    ///
    /// The frame was captured before the pause. Appended with its own time it would start
    /// the writer's session there, and `last − first` would count the pause as footage — a
    /// frozen stretch in the file and every later click early by its length (docs/17
    /// T-REC-1). Stamped with the live sample's time, the segment starts where the
    /// recording clock restarts, so the file and the telemetry agree.
    private func seedHeldFrame(into writer: any SegmentWriting, at box: SampleBufferBox) async {
        guard !segmentHasVideo, let lastVideoBox else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(box.buffer)
        guard let held = lastVideoBox.retimed(to: time) else { return }
        let accepted = await writer.append(held)
        segmentHasVideo = accepted
        if !accepted, let reason = await writer.failureReason {
            noteInterruption(.writerFailed(reason))
        }
    }

    func noteInterruption(_ event: RecordingEngineEvent) {
        if interruptionReason == nil {
            switch event {
            case let .streamStopped(message), let .writerFailed(message):
                interruptionReason = message
            }
        }
        eventsContinuation.yield(event)
    }

    func beginActivity() {
        endActivity()
        activitySession = activityAsserter.begin()
    }

    func endActivity() {
        activitySession?.end()
        activitySession = nil
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
