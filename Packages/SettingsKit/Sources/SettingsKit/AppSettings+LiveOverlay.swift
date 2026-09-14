import Foundation
import Shared

/// Live recording overlay and area-selection aspect (computed so they do not grow `init`).
public extension AppSettings {
    /// True when a permission request may need a relaunch, so setup returns to that screen.
    var resumeOnboardingAtPermissions: Bool {
        get {
            access(keyPath: \.resumeOnboardingAtPermissions)
            return store[SettingKeys.resumeOnboardingAtPermissions]
        }
        set {
            withMutation(keyPath: \.resumeOnboardingAtPermissions) {
                store[SettingKeys.resumeOnboardingAtPermissions] = newValue
            }
        }
    }

    /// Card actions stay visible instead of appearing on hover.
    var overlayAlwaysShowActions: Bool {
        get {
            access(keyPath: \.overlayAlwaysShowActions)
            return store[SettingKeys.overlayAlwaysShowActions]
        }
        set {
            withMutation(keyPath: \.overlayAlwaysShowActions) {
                store[SettingKeys.overlayAlwaysShowActions] = newValue
            }
        }
    }

    /// Teaching copy on the idle freeze overlay.
    var captureShowsOverlayHints: Bool {
        get {
            access(keyPath: \.captureShowsOverlayHints)
            return store[SettingKeys.captureShowsOverlayHints]
        }
        set {
            withMutation(keyPath: \.captureShowsOverlayHints) {
                store[SettingKeys.captureShowsOverlayHints] = newValue
            }
        }
    }

    /// Open an editable review window after Capture Text.
    var ocrShowsReview: Bool {
        get {
            access(keyPath: \.ocrShowsReview)
            return store[SettingKeys.ocrShowsReview]
        }
        set {
            withMutation(keyPath: \.ocrShowsReview) {
                store[SettingKeys.ocrShowsReview] = newValue
            }
        }
    }

    var recordingWebcamCircular: Bool {
        get {
            access(keyPath: \.recordingWebcamCircular)
            return store[SettingKeys.recordingWebcamCircular]
        }
        set {
            withMutation(keyPath: \.recordingWebcamCircular) {
                store[SettingKeys.recordingWebcamCircular] = newValue
            }
        }
    }

    var recordingWebcamFillsFrame: Bool {
        get {
            access(keyPath: \.recordingWebcamFillsFrame)
            return store[SettingKeys.recordingWebcamFillsFrame]
        }
        set {
            withMutation(keyPath: \.recordingWebcamFillsFrame) {
                store[SettingKeys.recordingWebcamFillsFrame] = newValue
            }
        }
    }

    var recordingWebcamCorner: RecordingWebcamCorner {
        get {
            access(keyPath: \.recordingWebcamCorner)
            return store[SettingKeys.recordingWebcamCorner]
        }
        set {
            withMutation(keyPath: \.recordingWebcamCorner) {
                store[SettingKeys.recordingWebcamCorner] = newValue
            }
        }
    }

    var captureSelectionAspect: CaptureSelectionAspect {
        get {
            access(keyPath: \.captureSelectionAspect)
            return store[SettingKeys.captureSelectionAspect]
        }
        set {
            withMutation(keyPath: \.captureSelectionAspect) {
                store[SettingKeys.captureSelectionAspect] = newValue
            }
        }
    }

    var recordingWebcamSize: Double {
        get {
            access(keyPath: \.recordingWebcamSize)
            return store[SettingKeys.recordingWebcamSize]
        }
        set {
            withMutation(keyPath: \.recordingWebcamSize) {
                store[SettingKeys.recordingWebcamSize] = min(max(newValue, 0.08), 0.6)
            }
        }
    }

    var recordingKeystrokePosition: RecordingKeystrokePosition {
        get {
            access(keyPath: \.recordingKeystrokePosition)
            return store[SettingKeys.recordingKeystrokePosition]
        }
        set {
            withMutation(keyPath: \.recordingKeystrokePosition) {
                store[SettingKeys.recordingKeystrokePosition] = newValue
            }
        }
    }

    var recordingKeystrokeAppearance: OverlayChromeAppearance {
        get {
            access(keyPath: \.recordingKeystrokeAppearance)
            return store[SettingKeys.recordingKeystrokeAppearance]
        }
        set {
            withMutation(keyPath: \.recordingKeystrokeAppearance) {
                store[SettingKeys.recordingKeystrokeAppearance] = newValue
            }
        }
    }

    var recordingKeystrokeScale: Double {
        get {
            access(keyPath: \.recordingKeystrokeScale)
            return store[SettingKeys.recordingKeystrokeScale]
        }
        set {
            withMutation(keyPath: \.recordingKeystrokeScale) {
                store[SettingKeys.recordingKeystrokeScale] = min(max(newValue, 0.6), 1.8)
            }
        }
    }

    var recordingClickFilled: Bool {
        get {
            access(keyPath: \.recordingClickFilled)
            return store[SettingKeys.recordingClickFilled]
        }
        set {
            withMutation(keyPath: \.recordingClickFilled) {
                store[SettingKeys.recordingClickFilled] = newValue
            }
        }
    }

    var recordingClickScale: Double {
        get {
            access(keyPath: \.recordingClickScale)
            return store[SettingKeys.recordingClickScale]
        }
        set {
            withMutation(keyPath: \.recordingClickScale) {
                store[SettingKeys.recordingClickScale] = min(max(newValue, 0.5), 4)
            }
        }
    }

    var recordingClickRed: Double {
        get {
            access(keyPath: \.recordingClickRed)
            return store[SettingKeys.recordingClickRed]
        }
        set {
            withMutation(keyPath: \.recordingClickRed) {
                store[SettingKeys.recordingClickRed] = min(max(newValue, 0), 1)
            }
        }
    }

    var recordingClickGreen: Double {
        get {
            access(keyPath: \.recordingClickGreen)
            return store[SettingKeys.recordingClickGreen]
        }
        set {
            withMutation(keyPath: \.recordingClickGreen) {
                store[SettingKeys.recordingClickGreen] = min(max(newValue, 0), 1)
            }
        }
    }

    var recordingClickBlue: Double {
        get {
            access(keyPath: \.recordingClickBlue)
            return store[SettingKeys.recordingClickBlue]
        }
        set {
            withMutation(keyPath: \.recordingClickBlue) {
                store[SettingKeys.recordingClickBlue] = min(max(newValue, 0), 1)
            }
        }
    }

    /// Which camera to record when the webcam is on. Empty is the system default.
    var recordingCameraDeviceID: String {
        get {
            access(keyPath: \.recordingCameraDeviceID)
            return store[SettingKeys.recordingCameraDeviceID]
        }
        set {
            withMutation(keyPath: \.recordingCameraDeviceID) {
                store[SettingKeys.recordingCameraDeviceID] = newValue
            }
        }
    }

    /// Which microphone to record when the mic is on. Empty is the system default.
    var recordingMicrophoneDeviceID: String {
        get {
            access(keyPath: \.recordingMicrophoneDeviceID)
            return store[SettingKeys.recordingMicrophoneDeviceID]
        }
        set {
            withMutation(keyPath: \.recordingMicrophoneDeviceID) {
                store[SettingKeys.recordingMicrophoneDeviceID] = newValue
            }
        }
    }
}
