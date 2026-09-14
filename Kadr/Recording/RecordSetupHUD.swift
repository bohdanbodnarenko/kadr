import AppKit
import OverlayKit
import RecordingCore
import SettingsKit
import Shared
import SwiftUI

/// Record mode: a compact picker strip, then start (docs/03 §1.4, §1.8).
///
/// Recording used to begin the instant a hotkey fired. The shortcut chose the target *and*
/// committed to it in one press, so there was no moment at which somebody could look at what
/// was about to happen and change their mind.
///
/// This is that moment, but it is not a form. Screendrop's picker is a row of icons that
/// *are* the start button — Display, Window, Area — with the mic, camera and timer sitting
/// beside them. The first version here was a 320-point card of switches and a "Start
/// Recording" button, which made every recording two decisions and a confirmation. One
/// click on a source starts it; the options are already decided in the same strip.
@MainActor
final class RecordSetupHUD {
    private let bar: RecordingControlBar
    private let model: RecordSetupModel
    private let composer = TeleprompterComposer()

    init(
        bar: RecordingControlBar,
        settings: AppSettings,
        start: @escaping (RecordTargetKind) -> Void,
        startDisplay: @escaping (CGDirectDisplayID) -> Void,
        cameraPreview: @escaping (Bool) -> Void = { _ in }
    ) {
        self.bar = bar
        model = RecordSetupModel(settings: settings, start: start)
        model.startDisplay = startDisplay
        model.onCameraPreview = cameraPreview
    }

    var isShowing: Bool {
        bar.isShowingPicker
    }

    /// Fired when the picker appears or goes away, so the menu bar can show the
    /// capture-armed state (docs/14 UX-08A).
    var onShowingChanged: (() -> Void)?

    func toggle() {
        if isShowing {
            model.cancel()
        } else {
            present()
        }
    }

    func present() {
        model.onStart = { [weak self] hidesBar in
            self?.composer.hide()
            if hidesBar {
                self?.dismiss()
            }
        }
        model.onCancel = { [weak self] in self?.dismiss() }
        model.onTeleprompterComposer = { [weak self] in
            guard let self else { return }
            composer.toggle(settings: model.settings, above: bar.screenFrame)
        }
        bar.showPicker(model: model)
        if model.settings.recordingShowsWebcam {
            model.onCameraPreview(true)
        }
        onShowingChanged?()
    }

    func dismiss() {
        composer.hide()
        bar.dismissPicker()
        onShowingChanged?()
    }
}

/// What a recording is pointed at, before a target has actually been chosen.
enum RecordTargetKind: String, CaseIterable, Identifiable {
    case area
    case window
    case screen

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .screen: "Screen"
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "menubar.rectangle"
        }
    }
}

@MainActor
@Observable
final class RecordSetupModel {
    let settings: AppSettings
    var displays: [RecordingDeviceCatalog.Display] = []
    var cameras: [RecordingDeviceCatalog.Device] = []
    var microphones: [RecordingDeviceCatalog.Device] = []

    @ObservationIgnored let start: (RecordTargetKind) -> Void
    /// Called just before a source begins. `hidesBar` is true for Area and Window, which
    /// need the overlay unobstructed; Display keeps the bar so it can morph into the
    /// countdown controls.
    @ObservationIgnored var onStart: (Bool) -> Void = { _ in }
    @ObservationIgnored var onCancel: () -> Void = {}
    /// Turns the live camera bubble on or off. Kept independent of the bar so Area and
    /// Window selection can hide the picker without tearing the session down.
    @ObservationIgnored var onCameraPreview: (Bool) -> Void = { _ in }
    /// Opens the script editor that belongs on the bar, not in Settings.
    @ObservationIgnored var onTeleprompterComposer: () -> Void = {}
    var accessPrompt: CaptureAccessKind?
    var accessResume: CaptureAccessResume?

    init(settings: AppSettings, start: @escaping (RecordTargetKind) -> Void) {
        self.settings = settings
        self.start = start
    }

    func refreshDevices() {
        displays = RecordingDeviceCatalog.displays()
        cameras = RecordingDeviceCatalog.cameras()
        microphones = RecordingDeviceCatalog.microphones()
    }

    func begin(_ kind: RecordTargetKind) {
        beginAfterAccessCheck(kind)
    }

    func beginDisplay(_ displayID: CGDirectDisplayID) {
        beginDisplayAfterAccessCheck(displayID)
    }

    /// Set by the HUD's owner so a multi-display pick can name a screen rather than
    /// always recording the main one.
    @ObservationIgnored var startDisplay: ((CGDirectDisplayID) -> Void)?

    func cancel() {
        onCameraPreview(false)
        onCancel()
    }
}
