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

    private let logger = KadrLog.logger(.recording)
    private let signposter = KadrLog.signposter(.recording)
    private let stitcher: any SegmentStitching
    private let compositor = FrameCompositor()
    let ownBundleIdentifier: String?

    private var stream: SCStream?
    private var output: StreamOutput?
    private var writer: SegmentWriter?
    private var consumeTask: Task<Void, Never>?

    private var options = RecordingOptions()
    private var pixelSize = PixelSize(width: 0, height: 0)
    private var segments: [URL] = []
    private var sessionDirectory: URL?
    var accumulatedDuration: TimeInterval = 0
    var segmentStartTime: CMTime?

    /// Supplies click halos, keystrokes and the webcam picture, frame by frame.
    ///
    /// Optional because a recording with no overlays should not pay for the machinery,
    /// and because the monitors that feed it belong to the app, not to the pipeline.
    private var overlayProvider: (any RecordingOverlayProviding)?

    public private(set) var state: RecordingState = .idle

    public init(
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        stitcher: any SegmentStitching = SegmentStitcher()
    ) {
        self.ownBundleIdentifier = ownBundleIdentifier
        self.stitcher = stitcher
    }

    #if DEBUG
        /// Puts the engine into the state a running recording leaves it in.
        ///
        /// A test seam, and a deliberate one: everything upstream of `stop` needs
        /// ScreenCaptureKit and a real display, which CI has neither of — but the state
        /// machine `stop` drives is exactly where the review found a recording could brick
        /// (docs/07 C3). Debug-only, so it cannot exist in a shipped build.
        func primeForTesting(state: RecordingState, segments: [URL], sessionDirectory: URL?) {
            self.state = state
            self.segments = segments
            self.sessionDirectory = sessionDirectory
            accumulatedDuration = 1
            pixelSize = PixelSize(width: 100, height: 100)
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

    // MARK: - Lifecycle

    /// Starts recording. The first segment begins immediately.
    public func start(target: RecordingTarget, options: RecordingOptions) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        self.options = options

        let content = try await shareableContent()
        let capture = try makeFilter(for: target, in: content)
        pixelSize = capture.pixelSize

        // Everything for this recording lives in one directory, so a crash leaves an
        // obvious place to recover segments from.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kadr-Recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionDirectory = directory
        segments = []
        accumulatedDuration = 0

        try await beginSegment()
        try await startStream(filter: capture.filter, sourceRect: capture.sourceRect)
        state = .recording
        logger.info(
            "Recording started at \(self.pixelSize.width, privacy: .public)×\(self.pixelSize.height, privacy: .public)"
        )
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
        try await beginSegment()
        state = .recording
    }

    /// Stops and returns the finished file.
    public func stop(savingTo destination: URL) async throws -> RecordingResult {
        guard state == .recording || state == .paused else { throw RecordingError.notRecording }
        state = .finishing

        // Whatever happens below, the engine comes back to `.idle`. Leaving it in
        // `.finishing` is what made a single failed stitch brick recording until relaunch:
        // the menu bar reads "not recording" while every later start throws (docs/07 C3).
        defer { state = .idle }

        await closeSegment()
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
                options: options
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
        await writer?.cancel()
        writer = nil
        await stopStream()
        for segment in segments {
            try? FileManager.default.removeItem(at: segment)
        }
        cleanUp()
        state = .idle
        logger.info("Recording cancelled")
    }

    // MARK: - Segments

    private func beginSegment() async throws {
        guard let sessionDirectory else { throw RecordingError.notRecording }
        // Each segment carries its own timeline; overlay timing counts from the whole
        // recording, so the segment's origin is reset and the accumulated duration added.
        segmentStartTime = nil
        let url = sessionDirectory.appendingPathComponent("segment-\(segments.count).mp4")
        writer = try SegmentWriter(
            fileURL: url,
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height,
            options: options
        )
    }

    private func closeSegment() async {
        guard let writer else { return }
        accumulatedDuration += await writer.duration
        if let url = await writer.finish() {
            segments.append(url)
        }
        self.writer = nil
    }

    private func cleanUp() {
        releaseSession(deletingFiles: true)
    }

    /// Lets go of the session.
    ///
    /// - Parameter deletingFiles: false leaves the segments on disk, which is what a
    ///   failed stitch needs — the engine is finished with them, the user is not.
    private func releaseSession(deletingFiles: Bool) {
        consumeTask?.cancel()
        consumeTask = nil
        output = nil
        segments = []
        if deletingFiles, let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        sessionDirectory = nil
    }

    // MARK: - Stream

    private func startStream(filter: SCContentFilter, sourceRect: CGRect?) async throws {
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

    private func stopStream() async {
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
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.kadr.recording.samples", qos: .userInitiated)
    private let continuation: AsyncStream<SampleBufferBox>.Continuation
    let buffers: AsyncStream<SampleBufferBox>
    private let logger = KadrLog.logger(.recording)

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
            let raw = attachments.first?[.contentRect] as? [String: Any]
        else {
            return nil
        }
        return CGRect(dictionaryRepresentation: raw as CFDictionary)
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
