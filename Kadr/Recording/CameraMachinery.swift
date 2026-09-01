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
    private let sessionQueue = DispatchQueue(label: "app.kadr.recording.camera-session")
    private let videoQueue = DispatchQueue(label: "app.kadr.recording.camera-video")
    private let writeQueue = DispatchQueue(label: "app.kadr.recording.camera-write")
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
            ?? AVCaptureDevice.default(for: .video)
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

        sessionQueue.async { [self] in
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

        writeQueue.sync {
            self.writer = writer
            writerInput = video
            outputURL = url
            sessionStart = nil
            latestSample = nil
            isPaused = false
            pauseBegan = nil
            pauseOffset = .zero
            resumeNeedsOffset = false
            isWriting = true
            lock.lock()
            firstFrameUptime = nil
            lock.unlock()
        }
        return true
    }

    func pauseWriting() {
        writeQueue.async { [self] in
            guard isWriting, !isPaused else { return }
            isPaused = true
            pauseBegan = latestSample
        }
    }

    func resumeWriting() {
        writeQueue.async { [self] in
            guard isWriting, isPaused else { return }
            isPaused = false
            resumeNeedsOffset = true
        }
    }

    func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            writeQueue.async { [self] in
                guard let writer, isWriting else {
                    stopSessionNow()
                    continuation.resume(returning: false)
                    return
                }
                isWriting = false
                writerInput?.markAsFinished()
                writer.finishWriting { [self] in
                    writeQueue.async { [self] in
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
        writeQueue.async { [self] in
            isWriting = false
            writer?.cancelWriting()
            resetWriter()
            stopSessionNow()
        }
    }

    func cancel() {
        writeQueue.async { [self] in
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
        guard let copy = Self.copy(sampleBuffer) else { return }
        let boxed = SampleBox(sample: copy)
        writeQueue.async { [self] in
            append(boxed.sample)
        }
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
        sessionQueue.async { [self] in
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

    private static func copy(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
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

    /// Carries a sample buffer onto the write queue.
    private struct SampleBox: @unchecked Sendable {
        let sample: CMSampleBuffer
    }
}
