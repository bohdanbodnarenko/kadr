import SettingsKit
import SwiftUI

extension RecordSetupModel {
    var accessPromptItem: Binding<CaptureAccessKind?> {
        Binding(
            get: { self.accessPrompt },
            set: { newValue in
                if newValue == nil {
                    self.dismissAccessPrompt()
                } else {
                    self.accessPrompt = newValue
                }
            }
        )
    }

    func requestCameraToggle() {
        if settings.recordingShowsWebcam {
            settings.recordingShowsWebcam = false
            onCameraPreview(false)
            return
        }
        armCamera()
    }

    func selectCamera(deviceID: String) {
        settings.recordingCameraDeviceID = deviceID
        armCamera()
    }

    func requestMicrophoneEnabled(_ enabled: Bool) {
        if !enabled {
            settings.recordsMicrophone = false
            return
        }
        if CaptureAccessGate.needsPrompt(status: CaptureMediaAccess.status(for: .microphone)) {
            accessResume = .toggle
            accessPrompt = .microphone
            return
        }
        settings.recordsMicrophone = true
    }

    func beginAfterAccessCheck(_ kind: RecordTargetKind) {
        if needsCameraPrompt {
            accessResume = .begin(kind)
            accessPrompt = .camera
            return
        }
        if needsMicrophonePrompt {
            accessResume = .begin(kind)
            accessPrompt = .microphone
            return
        }
        commitStart(kind)
    }

    func beginDisplayAfterAccessCheck(_ displayID: CGDirectDisplayID) {
        if needsCameraPrompt {
            accessResume = .beginDisplay(displayID)
            accessPrompt = .camera
            return
        }
        if needsMicrophonePrompt {
            accessResume = .beginDisplay(displayID)
            accessPrompt = .microphone
            return
        }
        commitDisplay(displayID)
    }

    func allowAccess() {
        guard let kind = accessPrompt else { return }
        Task {
            let granted = await CaptureMediaAccess.request(kind)
            if granted {
                applyGrant(kind)
                resumeAfterAccess()
            }
        }
    }

    func openAccessSettings() {
        guard let kind = accessPrompt else { return }
        CaptureMediaAccess.openSystemSettings(kind)
    }

    func useWithoutAccess() {
        guard let kind = accessPrompt else { return }
        switch kind {
        case .camera:
            settings.recordingShowsWebcam = false
            onCameraPreview(false)
        case .microphone:
            settings.recordsMicrophone = false
        }
        accessPrompt = nil
        continueResume(skipping: kind)
    }

    func refreshAfterPermissionChange() {
        guard let kind = accessPrompt else { return }
        guard CaptureMediaAccess.status(for: kind) == .allowed else { return }
        applyGrant(kind)
        resumeAfterAccess()
    }

    private var needsCameraPrompt: Bool {
        settings.recordingShowsWebcam
            && CaptureAccessGate.needsPrompt(status: CaptureMediaAccess.status(for: .camera))
    }

    private var needsMicrophonePrompt: Bool {
        settings.recordsMicrophone
            && CaptureAccessGate.needsPrompt(status: CaptureMediaAccess.status(for: .microphone))
    }

    private func armCamera() {
        if CaptureAccessGate.needsPrompt(status: CaptureMediaAccess.status(for: .camera)) {
            accessResume = .toggle
            accessPrompt = .camera
            return
        }
        enableCamera()
    }

    private func enableCamera() {
        if settings.recordingCameraDeviceID.isEmpty {
            settings.recordingCameraDeviceID = cameras.first?.uniqueID ?? ""
        }
        settings.recordingShowsWebcam = true
        onCameraPreview(true)
    }

    private func applyGrant(_ kind: CaptureAccessKind) {
        switch kind {
        case .camera:
            enableCamera()
        case .microphone:
            settings.recordsMicrophone = true
        }
        accessPrompt = nil
    }

    private func resumeAfterAccess() {
        continueResume(skipping: nil)
    }

    private func continueResume(skipping skipped: CaptureAccessKind?) {
        let resume = accessResume
        accessResume = nil
        switch resume {
        case .toggle, .none:
            return
        case let .begin(kind):
            if skipped == .camera, needsMicrophonePrompt {
                accessResume = .begin(kind)
                accessPrompt = .microphone
                return
            }
            commitStart(kind)
        case let .beginDisplay(displayID):
            if skipped == .camera, needsMicrophonePrompt {
                accessResume = .beginDisplay(displayID)
                accessPrompt = .microphone
                return
            }
            commitDisplay(displayID)
        }
    }

    private func dismissAccessPrompt() {
        accessPrompt = nil
        accessResume = nil
    }

    private func commitStart(_ kind: RecordTargetKind) {
        onStart(kind != .screen)
        start(kind)
    }

    private func commitDisplay(_ displayID: CGDirectDisplayID) {
        onStart(false)
        startDisplay?(displayID)
    }
}
