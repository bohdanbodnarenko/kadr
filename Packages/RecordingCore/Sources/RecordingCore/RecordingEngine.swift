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
    private let logger = KadrLog.logger(.recording)
    private let signposter = KadrLog.signposter(.recording)
    private let stitcher = SegmentStitcher()
    private let ownBundleIdentifier: String?

    private var stream: SCStream?
    private var output: StreamOutput?
    private var writer: SegmentWriter?
    private var consumeTask: Task<Void, Never>?

    private var options = RecordingOptions()
    private var pixelSize = PixelSize(width: 0, height: 0)
    private var segments: [URL] = []
    private var sessionDirectory: URL?
    private var accumulatedDuration: TimeInterval = 0

    public private(set) var state: RecordingState = .idle

    public init(ownBundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    // MARK: - Lifecycle

    /// Starts recording. The first segment begins immediately.
    public func start(target: RecordingTarget, options: RecordingOptions) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        self.options = options

        let content = try await shareableContent()
        let (filter, size) = try makeFilter(for: target, in: content)
        pixelSize = size

        // Everything for this recording lives in one directory, so a crash leaves an
        // obvious place to recover segments from.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kadr-Recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionDirectory = directory
        segments = []
        accumulatedDuration = 0

        try await beginSegment()
        try await startStream(filter: filter)
        state = .recording
        logger.info("Recording started at \(size.width, privacy: .public)×\(size.height, privacy: .public)")
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

        await closeSegment()
        await stopStream()

        guard !segments.isEmpty else {
            cleanUp()
            throw RecordingError.noFramesCaptured
        }

        let url = try await stitcher.stitch(segments, to: destination)
        let result = RecordingResult(
            fileURL: url,
            duration: accumulatedDuration,
            pixelSize: pixelSize,
            options: options
        )
        cleanUp()
        state = .idle
        return result
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
        consumeTask?.cancel()
        consumeTask = nil
        output = nil
        segments = []
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        sessionDirectory = nil
    }

    // MARK: - Stream

    private func startStream(filter: SCContentFilter) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate.rawValue))
        configuration.showsCursor = options.showsCursor
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = options.excludesOwnAudio
        // IOSurface-backed buffers straight from SCK's pool; the default depth of 3 is
        // deliberate — each retained frame is a full surface charged partly to
        // WindowServer, and raising it without measurement is how recordings start
        // costing hundreds of megabytes (docs/04 §4.3).
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

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

    /// Writes one buffer, if the recording is running.
    private func consume(_ box: SampleBufferBox) async {
        guard state == .recording, let writer else { return }
        await writer.append(box)
    }

    // MARK: - Targets

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecordingError.targetUnavailable
        }
    }

    private func makeFilter(
        for target: RecordingTarget,
        in content: SCShareableContent
    ) throws -> (SCContentFilter, PixelSize) {
        switch target {
        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingError.targetUnavailable
            }
            let filter = filterExcludingOwnWindows(display: display, in: content)
            return (filter, pixelSize(of: filter))

        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingError.targetUnavailable
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return (filter, pixelSize(of: filter))

        case let .region(rect, displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingError.targetUnavailable
            }
            let filter = filterExcludingOwnWindows(display: display, in: content)
            let scale = CGFloat(filter.pointPixelScale)
            let geometry = DisplayGeometry(
                displayID: displayID,
                frame: DisplayRect(cgRect: display.frame),
                scale: DisplayScale(scale)
            )
            guard let clamped = geometry.clamped(rect) else { throw RecordingError.targetUnavailable }
            let pixels = geometry.pixels(for: geometry.localRect(for: clamped))
            // Even dimensions: hardware encoders reject odd ones.
            return (filter, PixelSize(width: even(pixels.width), height: even(pixels.height)))
        }
    }

    private func filterExcludingOwnWindows(display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        guard let ownBundleIdentifier else {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        let own = content.applications.filter { $0.bundleIdentifier == ownBundleIdentifier }
        guard !own.isEmpty else {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        // The recording HUD and the stop button belong to Kadr, and none of it should
        // appear in the recording (docs/03 §1.8).
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }

    private func pixelSize(of filter: SCContentFilter) -> PixelSize {
        let scale = CGFloat(filter.pointPixelScale)
        return PixelSize(
            width: even(Int((filter.contentRect.width * scale).rounded())),
            height: even(Int((filter.contentRect.height * scale).rounded()))
        )
    }

    /// Hardware encoders require even dimensions.
    private func even(_ value: Int) -> Int {
        value % 2 == 0 ? value : value - 1
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
        let (stream, continuation) = AsyncStream<SampleBufferBox>.makeStream()
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
            continuation.yield(SampleBufferBox(buffer: sampleBuffer, kind: .video))
        case .audio:
            continuation.yield(SampleBufferBox(buffer: sampleBuffer, kind: .systemAudio))
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("Recording stream stopped: \(error.localizedDescription, privacy: .public)")
        continuation.finish()
    }

    func finish() {
        continuation.finish()
    }

    /// Reads SCK's per-frame status out of the buffer's attachments.
    private func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }
}
