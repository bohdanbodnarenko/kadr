import AVFoundation
import Foundation
import os
import Shared

/// Records the webcam to its own file alongside a screen recording (docs/09 U3.4).
///
/// A separate file rather than a bubble burnt into the picture, because that is what lets
/// the bubble be moved, resized, rounded or removed after the fact. A baked bubble is a
/// decision made before the recording that cannot be revisited after it, which is most of
/// what the studio exists to avoid.
///
/// The camera is never opened twice: when a recording captures a studio session the live
/// overlay's webcam stays off, so exactly one `AVCaptureSession` holds the device.
@MainActor
final class CameraFileRecorder {
    private let logger = KadrLog.logger(.recording)
    private var machinery: CameraMachinery?

    /// Whether the machine has a camera at all, asked before offering to use one.
    static var hasCamera: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    /// Whether the user has already granted camera access.
    ///
    /// Checked rather than requested here: a permission dialog appearing at the instant a
    /// recording starts is a dialog in the recording.
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Asks for camera access, for the settings screen to call before a recording starts.
    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    var isRecording: Bool {
        machinery != nil
    }

    /// Starts recording the camera into `url`.
    ///
    /// Best-effort by design: no camera, no permission, or a device already in use costs
    /// the bubble and never the screen recording. A webcam that fails to start must not
    /// take the thing the user actually asked for down with it.
    func start(writingTo url: URL) {
        guard machinery == nil else { return }
        guard Self.isAuthorized else {
            logger.info("Camera access not granted; recording without a camera track")
            return
        }
        let machinery = CameraMachinery()
        guard machinery.start(writingTo: url) else {
            logger.info("Could not start the camera; recording without a camera track")
            return
        }
        self.machinery = machinery
    }

    /// Stops and waits for the file to be finalised.
    ///
    /// Awaited rather than fired and forgotten: `AVCaptureMovieFileOutput` finishes writing
    /// asynchronously, and a session package assembled before the camera file is closed
    /// contains a movie nobody can open.
    @discardableResult
    func finish() async -> Bool {
        guard let machinery else { return false }
        self.machinery = nil
        return await machinery.finish()
    }

    func cancel() {
        machinery?.cancel()
        machinery = nil
    }
}

/// The capture objects and the one queue that owns them.
///
/// `AVCaptureSession` carries no `Sendable` conformance and `startRunning` blocks, so it
/// never leaves this type and every touch goes through `run` — the same documented pattern
/// the live webcam overlay uses (docs/04 §8).
///
/// The recording delegate is a separate object rather than this one. `AVCaptureFileOutput`
/// declares its delegate main-actor isolated, and conforming here would drag the whole type
/// — capture session included — onto the main actor, which is exactly where a blocking
/// `startRunning` must not be.
private final nonisolated class CameraMachinery: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "app.kadr.recording.camera-file")
    private let logger = KadrLog.logger(.recording)
    private let lock = NSLock()
    private var completion: (@Sendable (Bool) -> Void)?
    private var delegate: CameraRecordingDelegate?

    func start(writingTo url: URL) -> Bool {
        // 720p rather than the highest the camera offers: the bubble is a fraction of the
        // frame, and a 4K webcam track costs more to encode than the screen it sits on.
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(output)
        else {
            return false
        }
        session.addInput(input)
        session.addOutput(output)

        let delegate = CameraRecordingDelegate { [weak self] error in
            self?.finished(with: error)
        }
        self.delegate = delegate

        run { session, output in
            session.startRunning()
            output.startRecording(to: url, recordingDelegate: delegate)
        }
        return true
    }

    func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            completion = { continuation.resume(returning: $0) }
            lock.unlock()

            run { session, output in
                guard output.isRecording else {
                    // Never started, so the delegate will not fire and the continuation
                    // would be waiting for a callback that is not coming.
                    session.stopRunning()
                    self.complete(false)
                    return
                }
                output.stopRecording()
            }
        }
    }

    func cancel() {
        run { session, output in
            if output.isRecording {
                output.stopRecording()
            }
            session.stopRunning()
        }
        complete(false)
    }

    private func finished(with error: (any Error)?) {
        run { session, _ in session.stopRunning() }
        if let error {
            logger.error("The camera track failed: \(error.localizedDescription, privacy: .public)")
        }
        complete(error == nil)
    }

    /// Resumes the waiter once, whichever path reaches it first.
    private func complete(_ success: Bool) {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        completion?(success)
    }

    /// Runs an operation against the capture objects on the queue that owns them.
    private func run(_ operation: @escaping @Sendable (AVCaptureSession, AVCaptureMovieFileOutput) -> Void) {
        let boxed = Box(session: session, output: output)
        queue.async { operation(boxed.session, boxed.output) }
    }

    /// Carries the non-`Sendable` capture objects onto their own queue.
    private struct Box: @unchecked Sendable {
        let session: AVCaptureSession
        let output: AVCaptureMovieFileOutput
    }
}

private typealias RecordingDelegate = AVCaptureFileOutputRecordingDelegate

/// Forwards the one delegate callback that matters, and nothing else.
private final nonisolated class CameraRecordingDelegate: NSObject, RecordingDelegate, @unchecked Sendable {
    private let onFinish: @Sendable ((any Error)?) -> Void

    init(onFinish: @escaping @Sendable ((any Error)?) -> Void) {
        self.onFinish = onFinish
        super.init()
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        onFinish(error)
    }
}
