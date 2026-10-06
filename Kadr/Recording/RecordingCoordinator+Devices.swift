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

    /// What the take is recording from, when a device goes.
    struct TakeInputs: Equatable {
        /// The take's microphone, empty for the system default, nil for none.
        var microphoneID: String?
        /// The take's camera, nil for none.
        var cameraID: String?
        /// Inputs still attached; the default follows whichever is left, so it is only
        /// lost when none is.
        var remainingAudioDevices: Int
    }

    /// The disconnected device, as the notification describes it.
    struct Disconnection: Equatable {
        var uniqueID: String
        var isAudio: Bool
        var isVideo: Bool
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
            Disconnection(uniqueID: uniqueID, isAudio: isAudio, isVideo: isVideo),
            from: TakeInputs(
                microphoneID: microphoneThisTake && !microphoneDropped ? settings.recordingMicrophoneDeviceID : nil,
                cameraID: cameraThisTake,
                remainingAudioDevices: RecordingDeviceCatalog.microphones().count
            )
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

    static func lostInput(_ device: Disconnection, from take: TakeInputs) -> LostInput? {
        if device.isAudio, let microphoneID = take.microphoneID {
            if microphoneID == device.uniqueID || (microphoneID.isEmpty && take.remainingAudioDevices == 0) {
                return .microphone
            }
        }
        if device.isVideo, let cameraID = take.cameraID, cameraID == device.uniqueID {
            return .camera
        }
        return nil
    }
}
