import AVFoundation
import CoreImage
import Foundation
import os

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

        let reader = try makeReader(state)
        let writer = try makeWriter(destination: destination, size: plan.outputSize, options: options, state: state)

        guard reader.reader.startReading() else {
            throw RenderError.couldNotCreateReader(reader.reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.writer.startWriting() else {
            throw RenderError.couldNotCreateWriter(writer.writer.error?.localizedDescription ?? "unknown")
        }
        writer.writer.startSession(atSourceTime: CMTime.zero)

        var frameCount = 0
        var lastCamera: CIImage?
        var pendingCamera = reader.camera.flatMap { copyImage(from: $0) }
        let total = max(state.duration, 0.0001)

        while let screen = reader.screen.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(screen)
            let seconds = CMTimeGetSeconds(time)
            guard let sourceImage = image(from: screen) else { continue }

            // The camera is pulled forward to the screen frame rather than read in
            // lockstep: the webcam runs at its own rate — usually 30 against the screen's
            // 60 — so holding the most recent frame is what keeps the bubble showing a
            // face instead of flickering to black on every other frame.
            while let pending = pendingCamera, pending.time <= seconds {
                lastCamera = pending.image
                pendingCamera = reader.camera.flatMap { copyImage(from: $0) }
            }

            let composed = composer.frame(at: seconds, source: sourceImage, camera: lastCamera)
            try await append(composed, at: time, to: writer, size: plan.outputSize)
            frameCount += 1

            // Audio is interleaved here rather than written in a pass of its own. A file
            // whose sound is all at the front plays locally and seeks badly everywhere
            // else, and "it works on my machine" is exactly the failure a screen recorder
            // must not ship.
            try await drainAudio(upTo: time, reader: reader, writer: writer)
            progress?(min(seconds / total, 1))
        }

        // Whatever audio outlasts the last video frame. A recording that ends mid-sentence
        // because the final frame arrived first is a real thing.
        try await drainAudio(upTo: CMTime.positiveInfinity, reader: reader, writer: writer)

        writer.video.markAsFinished()
        writer.audio?.markAsFinished()
        await writer.writer.finishWriting()

        if writer.writer.status == .failed {
            throw RenderError.writingFailed(writer.writer.error?.localizedDescription ?? "unknown")
        }
        guard frameCount > 0 else {
            throw RenderError.writingFailed("no frames were composed")
        }
        progress?(1)

        return Output(
            fileURL: destination,
            pixelSize: plan.outputSize,
            duration: state.duration,
            frameCount: frameCount
        )
    }

    // MARK: - Reading

    /// The reader and its outputs.
    struct ReaderBundle {
        let reader: AVAssetReader
        let screen: AVAssetReaderTrackOutput
        let camera: AVAssetReaderTrackOutput?
        let audio: AVAssetReaderTrackOutput?
    }

    private func makeReader(_ state: RenderState) throws -> ReaderBundle {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: state.composition)
        } catch {
            throw RenderError.couldNotCreateReader(error.localizedDescription)
        }
        // BGRA out of the decoder: CoreImage's native layout, so composing costs no
        // conversion. Asking for the compressed format and converting per frame is the
        // single most expensive thing a render loop can get wrong.
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

        var audio: AVAssetReaderTrackOutput?
        if let track = state.audioTrack {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM
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
        let audio: AVAssetWriterInput?
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
            writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        } catch {
            throw RenderError.couldNotCreateWriter(error.localizedDescription)
        }

        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: options.frameRate,
            AVVideoMaxKeyFrameIntervalKey: options.frameRate * 2
        ]
        compression[AVVideoAverageBitRateKey] = options.bitRate ?? Self.bitRate(for: size, frameRate: options.frameRate)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression
        ])
        video.expectsMediaDataInRealTime = false
        guard writer.canAdd(video) else {
            throw RenderError.couldNotCreateWriter("the writer refused a \(Int(size.width))×\(Int(size.height)) input")
        }
        writer.add(video)

        var audio: AVAssetWriterInput?
        if state.audioTrack != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        return WriterBundle(writer: writer, video: video, audio: audio, adaptor: adaptor)
    }

    /// Composes one frame into a pooled buffer and appends it.
    private func append(
        _ image: CIImage,
        at time: CMTime,
        to writer: WriterBundle,
        size: CGSize
    ) async throws {
        try await waitUntilReady(writer.video)
        guard let pool = writer.adaptor.pixelBufferPool else {
            throw RenderError.writingFailed("the writer produced no pixel-buffer pool")
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer
        else {
            throw RenderError.writingFailed("could not take a pixel buffer from the pool")
        }

        // Rendered through the shared context so the compiled kernels and the texture
        // cache survive between frames — building a context per frame is most of the cost
        // of a frame.
        StudioRenderContext.shared.render(
            image,
            to: buffer,
            bounds: CGRect(origin: .zero, size: size),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        guard writer.adaptor.append(buffer, withPresentationTime: time) else {
            throw RenderError.writingFailed(writer.writer.error?.localizedDescription ?? "a frame was refused")
        }
    }

    /// Copies audio through until it has caught up with the video.
    private func drainAudio(
        upTo time: CMTime,
        reader: ReaderBundle,
        writer: WriterBundle
    ) async throws {
        guard let output = reader.audio, let input = writer.audio else { return }
        let limit = time == .positiveInfinity ? Double.infinity : CMTimeGetSeconds(time)
        while true {
            try await waitUntilReady(input)
            guard let sample = output.copyNextSampleBuffer() else { return }
            input.append(sample)
            if CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) >= limit {
                return
            }
        }
    }

    /// Waits for an input to want more data.
    ///
    /// A poll rather than `requestMediaDataWhenReady(on:using:)`, which would mean a
    /// dispatch queue and a continuation to hand each frame back to the render — for a
    /// flag that is almost always already true by the time the next frame is composed.
    /// The sleep is what stops the rare stall from becoming a spin.
    private func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - Pixels

    /// A `CIImage` for a decoded sample buffer.
    private func image(from sample: CMSampleBuffer) -> CIImage? {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        return CIImage(cvPixelBuffer: buffer)
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

    /// A bit rate for a size and a frame rate.
    ///
    /// Roughly 0.1 bits per pixel per frame, which is where HEVC stops showing blocking on
    /// screen content — text and flat colour, which compress well but show artefacts
    /// mercilessly. Screen recordings are not film and a film-derived table under-serves
    /// them badly.
    static func bitRate(for size: CGSize, frameRate: Int) -> Int {
        let pixels = Double(size.width * size.height)
        let estimate = pixels * Double(max(frameRate, 1)) * 0.1
        return Int(min(max(estimate, 1_500_000), 60_000_000))
    }
}
