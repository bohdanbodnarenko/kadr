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
/// overlay's webcam stays off, so exactly one `AVCaptureSession` holds the device. The
/// picker warms that session and shows a live preview; `start(writingTo:)` then writes from
/// the same session so the exposure fade-in is not in the file.
@MainActor
final class CameraFileRecorder {
    private let logger = KadrLog.logger(.recording)
    private let preview = CameraPreviewPanel()
    private var machinery: CameraMachinery?
    private var activeDeviceID: String?
    private var isWriting = false
    /// Bumps when the user toggles the camera, so a permission sheet that outlives a
    /// toggle-off does not start a session that was already cancelled.
    private var previewGeneration = 0

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
        isWriting
    }

    /// Warms the sensor and shows the circular preview, without writing a file yet.
    ///
    /// Called as soon as the camera is armed in the picker, and left running while Area or
    /// Window selection hides the bar. A no-op while a recording is already writing — that
    /// session owns the device until it finishes.
    func setPreview(enabled: Bool, deviceID: String?) {
        previewGeneration += 1
        let generation = previewGeneration
        guard enabled else {
            stopPreview()
            return
        }
        Task { await warmPreview(deviceID: deviceID, generation: generation) }
    }

    /// Starts recording the camera into `url`.
    ///
    /// Best-effort by design: no camera, no permission, or a device already in use costs
    /// the bubble and never the screen recording. A webcam that fails to start must not
    /// take the thing the user actually asked for down with it.
    ///
    /// Reuses a warm preview session for the same device when one is running, so the file
    /// does not begin with the fade-in the picker already showed.
    func start(writingTo url: URL, deviceID: String? = nil) {
        guard !isWriting else { return }
        if let machinery, matches(deviceID) {
            guard machinery.beginWriting(to: url) else {
                logger.info("Could not start the camera; recording without a camera track")
                return
            }
            isWriting = true
            preview.show(session: machinery.session)
            return
        }

        stopPreview()
        guard Self.isAuthorized else {
            logger.info("Camera access not granted; recording without a camera track")
            return
        }
        let machinery = CameraMachinery()
        guard machinery.startSession(deviceID: deviceID),
              machinery.beginWriting(to: url)
        else {
            machinery.stopSession()
            logger.info("Could not start the camera; recording without a camera track")
            return
        }
        self.machinery = machinery
        activeDeviceID = deviceID
        isWriting = true
        preview.show(session: machinery.session)
    }

    /// Stops writing frames for as long as the screen recording is paused, without
    /// tearing the preview down. Resume starts the file clock again after the gap.
    func pause() {
        machinery?.pauseWriting()
    }

    func resume() {
        machinery?.resumeWriting()
    }

    /// Stops, waits for the file to be finalised, and reports when the camera began.
    ///
    /// Awaited rather than fired and forgotten: the writer finishes asynchronously, and a
    /// session package assembled before the camera file is closed contains a movie nobody
    /// can open.
    ///
    /// The start time is the other half of the answer (docs/10 R0.5).
    ///
    /// The offset is the point of the return value. A capture session takes a moment to
    /// hand over its first frame — a third of a second built-in, well over a second on some
    /// external cameras — while the screen has been recording since before it was asked.
    /// Nothing downstream can discover that afterwards: both files start at zero and one of
    /// them started late.
    @discardableResult
    func finish() async -> (succeeded: Bool, startedAt: TimeInterval?) {
        guard let machinery else { return (false, nil) }
        preview.hide()
        isWriting = false
        activeDeviceID = nil
        self.machinery = nil
        let startedAt = machinery.startedAt
        return await (machinery.finish(), startedAt)
    }

    func cancel() {
        preview.hide()
        isWriting = false
        activeDeviceID = nil
        machinery?.cancel()
        machinery = nil
    }

    // MARK: - Preview

    private func warmPreview(deviceID: String?, generation: Int) async {
        if !Self.isAuthorized {
            let granted = await Self.requestAccess()
            guard granted else { return }
        }
        guard generation == previewGeneration else { return }
        startPreview(deviceID: deviceID)
    }

    private func startPreview(deviceID: String?) {
        guard !isWriting else {
            if let machinery {
                preview.show(session: machinery.session)
            }
            return
        }
        if let machinery, matches(deviceID) {
            preview.show(session: machinery.session)
            return
        }
        stopPreview()
        let machinery = CameraMachinery()
        guard machinery.startSession(deviceID: deviceID) else {
            logger.info("Could not start the camera preview")
            return
        }
        self.machinery = machinery
        activeDeviceID = deviceID
        preview.show(session: machinery.session)
    }

    /// Tears down a warm preview that never turned into a recording.
    ///
    /// No-op while a file is being written: the recording owns the session until Stop or
    /// Discard, and hiding the bubble must not close the device under it.
    private func stopPreview() {
        guard !isWriting else { return }
        preview.hide()
        machinery?.stopSession()
        machinery = nil
        activeDeviceID = nil
    }

    private func matches(_ deviceID: String?) -> Bool {
        (activeDeviceID ?? "") == (deviceID ?? "")
    }
}
