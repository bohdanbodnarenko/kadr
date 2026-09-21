import AVFoundation
import CoreImage
import Foundation
import os
import StudioSession

/// The render loop itself (docs/09 U3.3).
///
/// Split from the renderer's own file because setting a render up and running it fail for
/// different reasons and read very differently: preparation is a sequence of `await`s that
/// each give up, and this is one loop that must not.
extension StudioRenderer {
    /// Reads the composition frame by frame, composes each, and writes it.
    ///
    /// The plan comes off the composer rather than being passed alongside it: they must be
    /// the same plan, and two parameters that must agree are a way for them to disagree.
    func write(
        _ state: RenderState,
        composer: StudioFrameComposer,
        destination: URL,
        options: Options,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Output {
        let plan = composer.plan
        try? FileManager.default.removeItem(at: destination)

        // Every failure out of this function has to leave nothing behind (docs/10 R0.4).
        //
        // The destination is removed up front, so a render that throws halfway — cancelled,
        // out of disk, refused by the encoder — used to leave a partial `.mov` at the path
        // the user chose. The studio said the export failed and Finder showed a file that
        // played for seven minutes of a ten-minute recording, which is worse than no file:
        // one of those is obviously missing and the other is quietly wrong.
        //
        // The reader and writer are cancelled too. Left running they hold decoders, an
        // encode session and the destination's file handle for as long as the process
        // lives.
        // `open` holds whatever has been created so far, so the cleanup can reach it
        // whichever line threw.
        var finished = false
        var open = OpenResources()
        defer {
            if !finished {
                open.cancel()
                try? FileManager.default.removeItem(at: destination)
            }
        }

        let reader = try makeReader(state, options: options)
        open.reader = reader
        let writer = try makeWriter(destination: destination, size: plan.outputSize, options: options, state: state)
        open.writer = writer

        guard reader.reader.startReading() else {
            throw RenderError.couldNotCreateReader(reader.reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.writer.startWriting() else {
            throw RenderError.couldNotCreateWriter(writer.writer.error?.localizedDescription ?? "unknown")
        }
        writer.writer.startSession(atSourceTime: CMTime.zero)
        writer.audio?.attach(reader.audio)

        var throttle = ProgressThrottle(progress)
        let frameCount = try await renderLoop(
            state,
            composer: composer,
            io: (reader, writer),
            options: options,
            progress: &throttle
        )

        // Ask the reader *why* it stopped (docs/11 S0.4).
        //
        // `copyNextSampleBuffer` returns nil for two completely different things: the track
        // ended, or the reader died. Without this the second one looked exactly like the
        // first — a reader that failed at minute seven exited the loop cleanly, the writer
        // finalised a well-formed seven-minute file, and `StudioDocumentModel.export` wrote
        // a `RenderStamp` blessing it as the export of a ten-minute recording. Silent
        // truncation, with a certificate of authenticity attached.
        try check(reader.reader, expecting: state.duration)

        // The picture is finished before the last of the sound is copied, not after. While the
        // video input is still open the writer is waiting on it, and holds back the sound
        // that outlasts the last frame — so a drain that came first waited for the writer,
        // which was waiting for the picture that this was about to say was not coming.
        writer.video.markAsFinished()

        // Whatever audio outlasts the last video frame. A recording that ends mid-sentence
        // because the final frame arrived first is a real thing.
        try await drainAudio(upTo: CMTime.positiveInfinity, writer: writer)

        // The audio drain reads too, so the reader gets asked a second time.
        try check(reader.reader, expecting: state.duration)

        writer.audio?.finish()
        await writer.writer.finishWriting()

        if writer.writer.status == .failed {
            throw RenderError.writingFailed(writer.writer.error?.localizedDescription ?? "unknown")
        }
        guard frameCount > 0 else {
            throw RenderError.writingFailed("no frames were composed")
        }
        throttle.update(1)
        // Past every throw: the file at the destination is now the whole export.
        finished = true

        return Output(
            fileURL: destination,
            pixelSize: plan.outputSize,
            duration: state.duration,
            frameCount: frameCount
        )
    }

    /// The render loop, staged so the decoder and the GPU work at the same time.
    ///
    /// Each pass decodes and composes frame *N* and starts it on the GPU, then waits for
    /// frame *N − 1* — started on the previous pass — and hands that to the encoder. So
    /// while the GPU draws one frame, the decoder is already producing the next, where the
    /// old loop left each idle while the other worked. See `StudioRenderer+Pipeline.swift`
    /// for why the stages overlap by one frame inside one task rather than running as
    /// separate tasks with queues between them.
    ///
    /// Which frames are written is unchanged, line for line: a clip change forgets the last
    /// screen frame, each output time takes the latest decoded frame at or before it, a
    /// frame with no screen yet is skipped, and audio is interleaved after each frame is
    /// appended, up to that frame's time.
    private func renderLoop(
        _ state: RenderState,
        composer: StudioFrameComposer,
        io: (reader: ReaderBundle, writer: WriterBundle),
        options: Options,
        progress: inout ProgressThrottle
    ) async throws -> Int {
        let reader = io.reader
        let writer = io.writer
        var lastCamera: CIImage?
        var pendingCamera = reader.camera.flatMap { signpostedCopy(from: $0) }
        var lastScreen: CIImage?
        var pendingScreen = signpostedCopy(from: reader.screen)
        var lastClipID: Clip.ID?
        let fps = max(options.frameRate, 1)
        let frameCountTarget = VariableFrameClock.frameCount(duration: state.duration, frameRate: fps)
        var frameCount = 0
        let bounds = CGRect(origin: .zero, size: composer.plan.outputSize)
        // The frame on the GPU, waiting to be written.
        var inFlight: RenderedJob?

        for frame in 0 ..< frameCountTarget {
            try Task.checkCancellation()
            let time = VariableFrameClock.presentationTime(frame: frame, frameRate: fps)
            let seconds = CMTimeGetSeconds(time)
            let clipID = composer.edit.clips.clip(atEdited: seconds)?.id
            if clipID != lastClipID {
                lastScreen = nil
                lastClipID = clipID
            }
            while let pending = pendingScreen, pending.time <= seconds {
                lastScreen = pending.image
                pendingScreen = signpostedCopy(from: reader.screen)
            }
            while let pending = pendingCamera, pending.time <= seconds {
                lastCamera = pending.image
                pendingCamera = reader.camera.flatMap { signpostedCopy(from: $0) }
            }
            guard let sourceImage = lastScreen else { continue }
            let started = try await start(
                FrameJob(frame: frame, time: time, seconds: seconds, source: sourceImage, camera: lastCamera),
                composer: composer,
                bounds: bounds,
                writer: writer
            )
            if let previous = inFlight {
                try await finish(previous, frames: frameCountTarget, io: io, progress: &progress)
                frameCount += 1
            }
            inFlight = started
        }
        if let last = inFlight {
            try await finish(last, frames: frameCountTarget, io: io, progress: &progress)
            frameCount += 1
        }
        return frameCount
    }

    /// Composes a frame and starts drawing it into a buffer from the writer's pool.
    ///
    /// `startTask` rather than `render(_:to:)`: the recipe is compiled and the GPU work
    /// queued, and control comes straight back.
    private func start(
        _ job: FrameJob,
        composer: StudioFrameComposer,
        bounds: CGRect,
        writer: WriterBundle
    ) async throws -> RenderedJob {
        // Waited for here, as before, so a writer that is not yet taking frames is not
        // asked for a buffer; the pool exists from `startWriting` on.
        try await waitUntilReady(writer)
        let interval = Self.signposter.beginInterval("studio.export.compose")
        defer { Self.signposter.endInterval("studio.export.compose", interval) }
        guard let pool = writer.adaptor.pixelBufferPool else {
            throw RenderError.writingFailed("the writer produced no pixel-buffer pool")
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer
        else {
            throw RenderError.writingFailed("could not take a pixel buffer from the pool")
        }
        let image = composer.frame(at: job.seconds, source: job.source, camera: job.camera)
        // Rendered through the shared context so the compiled kernels and the texture
        // cache survive between frames — building a context per frame is most of the cost
        // of a frame. The same colour space and bounds the synchronous render used.
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = StudioRenderContext.sRGB
        destination.alphaMode = .premultiplied
        do {
            let task = try StudioRenderContext.shared.startTask(
                toRender: image,
                from: bounds,
                to: destination,
                at: .zero
            )
            return RenderedJob(frame: job.frame, time: job.time, buffer: buffer, task: task)
        } catch {
            throw RenderError.writingFailed(error.localizedDescription)
        }
    }

    /// Waits for a started frame, writes it, and brings the audio up to it.
    private func finish(
        _ job: RenderedJob,
        frames: Int,
        io: (reader: ReaderBundle, writer: WriterBundle),
        progress: inout ProgressThrottle
    ) async throws {
        try await append(job, to: io.writer)
        try await drainAudio(upTo: job.time, writer: io.writer)
        progress.update(min(Double(job.frame + 1) / Double(frames), 1))
    }

    /// Fails the render if the reader stopped for any reason but reaching the end.
    ///
    /// `.completed` is the only status that means "there was nothing more to read".
    /// `.failed` and `.cancelled` both surface as a `nil` sample buffer, indistinguishable
    /// at the call site from a track that simply ended — which is how a truncated export
    /// used to be written, finalised and stamped as authentic.
    func check(_ reader: AVAssetReader, expecting duration: TimeInterval) throws {
        switch reader.status {
        case .completed, .reading:
            return
        case .failed:
            throw RenderError.readingFailed(reader.error?.localizedDescription ?? "unknown")
        case .cancelled:
            throw RenderError.cancelled
        default:
            throw RenderError.readingFailed(
                "the reader stopped after less than the \(Int(duration))s the edit asks for"
            )
        }
    }

    /// What a failed render has to shut down and delete.
    ///
    /// A tiny box rather than two optionals threaded through the function, because the
    /// cleanup has to run from a `defer` declared before either exists — and a `defer` that
    /// can only see half of what a failure created is a `defer` that leaks the other half.
    struct OpenResources {
        var reader: ReaderBundle?
        var writer: WriterBundle?

        /// Left running, these hold decoders, an encode session and the destination's file
        /// handle for as long as the process lives.
        func cancel() {
            reader?.reader.cancelReading()
            writer?.writer.cancelWriting()
        }
    }

    // MARK: - Reading

    /// The reader and its outputs.
    struct ReaderBundle {
        let reader: AVAssetReader
        let screen: AVAssetReaderTrackOutput
        let camera: AVAssetReaderTrackOutput?
        let audio: AVAssetReaderAudioMixOutput?
    }

    private func makeReader(_ state: RenderState, options: Options) throws -> ReaderBundle {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: state.composition)
        } catch {
            throw RenderError.couldNotCreateReader(error.localizedDescription)
        }
        // BGRA out of the decoder: CoreImage's native layout, so composing costs no
        // conversion. Asking for the compressed format and converting per frame is the
        // single most expensive thing a render loop can get wrong.
        //
        // IOSurface/Metal-compatible keys were tried here and left out for now: they were
        // in place while the suite was hunting a process-wide reader stall, which turned
        // out to be cooperative-pool starvation (`ExportGate`), and they have not been
        // re-measured on their own since. The writer's side, which is ours to allocate, is
        // IOSurface-backed (`makeWriter`).
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let screen = AVAssetReaderTrackOutput(track: state.screenTrack, outputSettings: settings)
        screen.alwaysCopiesSampleData = false
        reader.add(screen)

        var camera: AVAssetReaderTrackOutput?
        if let track = state.cameraTrack {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                camera = output
            }
        }

        var audio: AVAssetReaderAudioMixOutput?
        if options.includeAudio, !state.audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: state.audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: options.audioChannelCount,
                AVSampleRateKey: 48000,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            if reader.canAdd(output) {
                reader.add(output)
                audio = output
            }
        }
        return ReaderBundle(reader: reader, screen: screen, camera: camera, audio: audio)
    }

    // MARK: - Writing

    /// The writer, its inputs and the pixel-buffer adaptor.
    struct WriterBundle {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AudioRelay?
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
    }

    private func makeWriter(
        destination: URL,
        size: CGSize,
        options: Options,
        state: RenderState
    ) throws -> WriterBundle {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: options.fileType)
        } catch {
            throw RenderError.couldNotCreateWriter(error.localizedDescription)
        }

        let compression = Self.compressionProperties(for: options, size: size)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression
        ])
        video.expectsMediaDataInRealTime = false
        writer.shouldOptimizeForNetworkUse = options.fileType == .mp4
        guard writer.canAdd(video) else {
            throw RenderError.couldNotCreateWriter("the writer refused a \(Int(size.width))×\(Int(size.height)) input")
        }
        writer.add(video)

        var audio: AudioRelay?
        if options.includeAudio, !state.audioTracks.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: options.aacSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audio = AudioRelay(input: input)
            }
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                // So CoreImage draws straight into the encoder's own memory.
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
        )
        return WriterBundle(writer: writer, video: video, audio: audio, adaptor: adaptor)
    }

    /// Waits for a frame's pixels and hands them to the encoder.
    private func append(_ job: RenderedJob, to writer: WriterBundle) async throws {
        let interval = Self.signposter.beginInterval("studio.export.write")
        defer { Self.signposter.endInterval("studio.export.write", interval) }
        do {
            _ = try job.task.waitUntilCompleted()
        } catch {
            throw RenderError.writingFailed(error.localizedDescription)
        }
        try await waitUntilReady(writer)
        guard writer.adaptor.append(job.buffer, withPresentationTime: job.time) else {
            throw RenderError.writingFailed(writer.writer.error?.localizedDescription ?? "a frame was refused")
        }
    }

    // MARK: - Pixels

    /// A `CIImage` for a decoded sample buffer.
    private func image(from sample: CMSampleBuffer) -> CIImage? {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }

    /// The same, inside the decode stage's signpost.
    private func signpostedCopy(from output: AVAssetReaderTrackOutput) -> (image: CIImage, time: TimeInterval)? {
        let interval = Self.signposter.beginInterval("studio.export.decode")
        defer { Self.signposter.endInterval("studio.export.decode", interval) }
        return copyImage(from: output)
    }

    /// The next camera frame and the instant it belongs to.
    private func copyImage(from output: AVAssetReaderTrackOutput) -> (image: CIImage, time: TimeInterval)? {
        guard let sample = output.copyNextSampleBuffer(),
              let image = image(from: sample)
        else {
            return nil
        }
        return (image, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
    }
}
