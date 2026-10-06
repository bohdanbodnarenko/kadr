import AVFoundation
import CoreMedia
import Foundation
import os
import Shared

/// The capture objects and the queues that own them.
///
/// `AVCaptureSession` carries no `Sendable` conformance and `startRunning` blocks, so it
/// never leaves this type. Frames are pulled as sample buffers rather than through
/// `AVCaptureMovieFileOutput`, because a movie-file output cannot pause: pausing the screen
/// would leave the camera file still running, and the talking-head would drift ahead of
/// the picture for the rest of the recording.
final nonisolated class CameraMachinery: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// OS-required handler queue (CLAUDE.md rule 5): `setSampleBufferDelegate(_:queue:)`.
    ///
    /// The only queue this type has. The blocking `startRunning`/`stopRunning` run on it
    /// too, as `WebcamCapture`'s do: a second queue just for them was one more than the
    /// rule allows (docs/17 T-REC-11), and nothing is lost — no frame arrives before the
    /// session runs, and one that is queued behind `stopRunning` was going to be dropped.
    ///
    /// Also the writer's queue. Every piece of writer state below is touched only here: the
    /// delegate appends synchronously on it, and the pause/resume/finish commands hop onto
    /// it. A separate write queue used to sit behind this one, which meant a copy of every
    /// sample buffer and an async hop per frame — and, when the encoder fell behind, an
    /// unbounded backlog of retained camera frames where `alwaysDiscardsLateVideoFrames`
    /// would otherwise have dropped them.
    private let videoQueue = DispatchQueue(label: "com.bohdanbodnarenko.kadr.recording.camera-video")
    private let logger = KadrLog.logger(.recording)
    private let lock = NSLock()

    private var input: AVCaptureDeviceInput?
    private let output = AVCaptureVideoDataOutput()
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var sessionStart: CMTime?
    private var latestSample: CMTime?
    private var isPaused = false
    private var pauseBegan: CMTime?
    private var pauseOffset: CMTime = .zero
    private var resumeNeedsOffset = false
    private var isWriting = false
    private var firstFrameUptime: TimeInterval?

    var startedAt: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return firstFrameUptime
    }

    /// Opens the device and starts running, without writing a file yet.
    func startSession(deviceID: String?) -> Bool {
        // 720p rather than the highest the camera offers: the bubble is a fraction of the
        // frame, and a 4K webcam track costs more to encode than the screen it sits on.
        session.sessionPreset = .hd1280x720
        let device = RecordingDeviceCatalog.camera(withID: deviceID ?? "")
        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            return false
        }
        session.beginConfiguration()
        session.addInput(input)
        self.input = input

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        session.commitConfiguration()

        videoQueue.async { [self] in
            session.startRunning()
        }
        return true
    }

    /// Starts writing from an already-running session.
    func beginWriting(to url: URL) -> Bool {
        let dimensions: CMVideoDimensions = if let device = input?.device {
            CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        } else {
            CMVideoDimensions(width: 1280, height: 720)
        }
        let width = max(2, (Int(dimensions.width) / 2) * 2)
        let height = max(2, (Int(dimensions.height) / 2) * 2)

        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            return false
        }
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(6_000_000, width * height * 6),
                AVVideoExpectedSourceFrameRateKey: 30
            ] as [String: Any]
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return false }
        writer.add(video)
        guard writer.startWriting() else { return false }

        lock.lock()
        firstFrameUptime = nil
        lock.unlock()
        // Async, not sync: the queue may be inside a blocking `startRunning`, and the main
        // thread must not wait that out. Every command after this one is queued behind it.
        // Ownership moves to the queue here: nothing on this side touches either object again.
        nonisolated(unsafe) let handedWriter = writer
        nonisolated(unsafe) let handedInput = video
        videoQueue.async { [self] in
            self.writer = handedWriter
            writerInput = handedInput
            outputURL = url
            sessionStart = nil
            latestSample = nil
            isPaused = false
            pauseBegan = nil
            pauseOffset = .zero
            resumeNeedsOffset = false
            isWriting = true
        }
        return true
    }

    func pauseWriting() {
        videoQueue.async { [self] in
            guard isWriting, !isPaused else { return }
            isPaused = true
            pauseBegan = latestSample
        }
    }

    func resumeWriting() {
        videoQueue.async { [self] in
            guard isWriting, isPaused else { return }
            isPaused = false
            resumeNeedsOffset = true
        }
    }

    func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            videoQueue.async { [self] in
                guard let writer, isWriting else {
                    stopSessionNow()
                    continuation.resume(returning: false)
                    return
                }
                isWriting = false
                writerInput?.markAsFinished()
                writer.finishWriting { [self] in
                    videoQueue.async { [self] in
                        let succeeded = self.writer?.status == .completed
                        if succeeded != true, let outputURL {
                            try? FileManager.default.removeItem(at: outputURL)
                        }
                        if let error = self.writer?.error, succeeded != true {
                            logger.error(
                                "The camera track failed: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                        resetWriter()
                        stopSessionNow()
                        continuation.resume(returning: succeeded == true)
                    }
                }
            }
        }
    }

    func stopSession() {
        videoQueue.async { [self] in
            isWriting = false
            writer?.cancelWriting()
            resetWriter()
            stopSessionNow()
        }
    }

    func cancel() {
        videoQueue.async { [self] in
            isWriting = false
            writer?.cancelWriting()
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            resetWriter()
            stopSessionNow()
        }
    }

    nonisolated func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        // Already on `videoQueue`, which owns the writer: no copy, no hop.
        append(sampleBuffer)
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, let writer, let writerInput, writer.status == .writing else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        latestSample = time

        if isPaused {
            if pauseBegan == nil {
                pauseBegan = time
            }
            return
        }

        if resumeNeedsOffset {
            if let pauseBegan {
                pauseOffset = CMTimeAdd(pauseOffset, CMTimeSubtract(time, pauseBegan))
                self.pauseBegan = nil
            }
            resumeNeedsOffset = false
        }

        if sessionStart == nil {
            sessionStart = time
            writer.startSession(atSourceTime: .zero)
            lock.lock()
            if firstFrameUptime == nil {
                firstFrameUptime = ProcessInfo.processInfo.systemUptime
            }
            lock.unlock()
        }

        guard let sessionStart else { return }
        let presentation = CameraWriteClock.fileTime(
            sampleTime: time,
            sessionStart: sessionStart,
            pauseOffset: pauseOffset
        )
        guard presentation >= .zero,
              writerInput.isReadyForMoreMediaData,
              let retimed = Self.retime(sampleBuffer, to: presentation)
        else {
            return
        }
        writerInput.append(retimed)
    }

    private func stopSessionNow() {
        videoQueue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
            session.beginConfiguration()
            if let input {
                session.removeInput(input)
            }
            if session.outputs.contains(output) {
                session.removeOutput(output)
            }
            session.commitConfiguration()
            input = nil
        }
    }

    private func resetWriter() {
        writer = nil
        writerInput = nil
        outputURL = nil
        sessionStart = nil
        latestSample = nil
        isPaused = false
        pauseBegan = nil
        pauseOffset = .zero
        resumeNeedsOffset = false
        isWriting = false
    }

    private static func retime(_ sampleBuffer: CMSampleBuffer, to presentation: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: presentation,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        return status == noErr ? retimed : nil
    }
}
