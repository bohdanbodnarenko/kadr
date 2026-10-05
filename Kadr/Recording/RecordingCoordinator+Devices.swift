import AVFoundation
import RecordingCore
import SettingsKit

/// A microphone or camera unplugged during a take (docs/18 REC-10).
///
/// Without this the take carried on with the input gone and nothing said so: the narration
/// simply stops in the file. The bar now says what went, and a lost microphone also raises
/// the whole-take "no microphone" glyph.
extension RecordingCoordinator {
    /// Which of the take's inputs a disconnection took away.
    enum LostInput: Equatable {
        case microphone
        case camera
    }

    /// Listens for device disconnections for the coordinator's lifetime.
    ///
    /// A notification, not polling, so an idle agent still costs nothing (rule 2); it acts
    /// only while a take is live.
    func listenForDeviceLoss() {
        let center = NotificationCenter.default
        deviceLossTask = Task { [weak self] in
            for await note in center.notifications(named: AVCaptureDevice.wasDisconnectedNotification) {
                guard let device = note.object as? AVCaptureDevice else { continue }
                let id = device.uniqueID
                let isAudio = device.hasMediaType(.audio)
                let isVideo = device.hasMediaType(.video)
                self?.deviceDisconnected(uniqueID: id, isAudio: isAudio, isVideo: isVideo)
            }
        }
    }

    func deviceDisconnected(uniqueID: String, isAudio: Bool, isVideo: Bool) {
        guard state == .recording || state == .paused else { return }
        let lost = Self.lostInput(
            disconnectedID: uniqueID,
            isAudio: isAudio,
            isVideo: isVideo,
            microphoneID: microphoneThisTake && !microphoneDropped ? settings.recordingMicrophoneDeviceID : nil,
            cameraID: cameraThisTake,
            remainingAudioDevices: RecordingDeviceCatalog.microphones().count
        )
        switch lost {
        case .microphone:
            microphoneDropped = true
            startNotice = String(localized: "Microphone disconnected — the rest of this take has no microphone.")
            showStartNotice()
        case .camera:
            cameraThisTake = nil
            startNotice = String(localized: "Camera disconnected — the rest of this take has no camera.")
            showStartNotice()
        case nil:
            break
        }
    }

    /// - Parameters:
    ///   - microphoneID: the take's microphone, empty for the system default, nil for none.
    ///   - cameraID: the take's camera, nil for none.
    ///   - remainingAudioDevices: inputs still attached; the default follows whichever is
    ///     left, so it is only lost when none is.
    static func lostInput(
        disconnectedID: String,
        isAudio: Bool,
        isVideo: Bool,
        microphoneID: String?,
        cameraID: String?,
        remainingAudioDevices: Int
    ) -> LostInput? {
        if isAudio, let microphoneID {
            if microphoneID == disconnectedID || (microphoneID.isEmpty && remainingAudioDevices == 0) {
                return .microphone
            }
        }
        if isVideo, let cameraID, cameraID == disconnectedID {
            return .camera
        }
        return nil
    }
}
