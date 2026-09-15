import RecordingCore
import SettingsKit
import SwiftUI

extension RecordSetupModel {
    var accessPromptItem: Binding<CaptureAccessKind?> {
        Binding(
            get: { self.accessPrompt },
            set: { newValue in
                if newValue == nil {
                    // The system camera sheet steals key status and dismisses this
                    // popover. Keep the in-flight resume so Allow can still restore
                    // the island instead of leaving only the camera bubble.
                    if self.accessRequestInFlight {
                        self.accessPrompt = nil
                    } else {
                        self.dismissAccessPrompt()
                    }
                } else {
                    self.accessPrompt = newValue
                }
            }
        )
    }

    func requestCameraToggle() {
        if settings.recordingShowsWebcam {
            if needsCameraPrompt {
                armCamera()
                return
            }
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

    func recordAfterAccessCheck() {
        if needsCameraPrompt {
            accessResume = .record
            accessPrompt = .camera
            return
        }
        if needsMicrophonePrompt {
            accessResume = .record
            accessPrompt = .microphone
            return
        }
        commitRecord()
    }

    func allowAccess() {
        guard let kind = accessPrompt else { return }
        let resume = accessResume
        accessRequestInFlight = true
        Task { @MainActor in
            let granted = await CaptureMediaAccess.request(kind)
            accessRequestInFlight = false
            guard granted else {
                onRevealAfterPick()
                return
            }
            applyGrant(kind)
            continueResume(resume, skipping: nil)
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
        continueResume(accessResume, skipping: kind)
    }

    func refreshAfterPermissionChange() {
        guard let kind = accessPrompt else { return }
        guard CaptureMediaAccess.status(for: kind) == .allowed else { return }
        applyGrant(kind)
        continueResume(accessResume, skipping: nil)
    }

    /// Completes a grant without the system sheet (tests, and returning from Settings).
    func completeAccessGrant(_ kind: CaptureAccessKind) {
        applyGrant(kind)
        continueResume(accessResume, skipping: nil)
    }

    var needsCameraPrompt: Bool {
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

    private func continueResume(_ resume: CaptureAccessResume?, skipping skipped: CaptureAccessKind?) {
        accessResume = nil
        switch resume {
        case .record:
            if skipped == .camera, needsMicrophonePrompt {
                accessResume = .record
                accessPrompt = .microphone
                return
            }
            commitRecord()
        case .toggle, .none:
            // The TCC sheet often dismisses the picker panel. Bring the island
            // back so the user is not left with only the camera bubble.
            onRevealAfterPick()
        }
    }

    private func dismissAccessPrompt() {
        accessPrompt = nil
        accessResume = nil
    }

    private func commitRecord() {
        guard let target = recordingTarget else { return }
        onCommit()
        recordAction(target)
        onCommitted()
    }
}
