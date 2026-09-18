import AppKit
import OverlayKit
import RecordingCore
import SelectionUI
import SettingsKit
import Shared
import SwiftUI

/// Record mode: a floating island, then Record (docs/03 §1.4, §1.8).
///
/// The island stays up so microphone, camera and the target can be chosen before anything
/// is captured. Screen / Window / Area arm a target; the red Record button is what starts
/// the countdown. Window and area open the same overlay stills use, then bring the island
/// back — they do not begin the take on the click.
@MainActor
final class RecordSetupHUD {
    private let bar: RecordingControlBar
    private let model: RecordSetupModel
    private let composer = TeleprompterComposer()
    /// The picked area, lit with the rest dimmed and a Record button inside it.
    private let stage = CaptureRegionStage()

    init(
        bar: RecordingControlBar,
        settings: AppSettings,
        record: @escaping (RecordingTarget) -> Void,
        pickWindow: @escaping (@escaping (WindowSelection?) -> Void) -> Void,
        pickArea: @escaping (@escaping (SelectionResult?) -> Void) -> Void,
        cameraPreview: @escaping (Bool) -> Void = { _ in }
    ) {
        self.bar = bar
        model = RecordSetupModel(settings: settings, record: record)
        model.onPickWindow = pickWindow
        model.onPickArea = pickArea
        model.onCameraPreview = cameraPreview
    }

    var isShowing: Bool {
        bar.isShowingPicker
    }

    /// Fired when the picker appears or goes away, so the menu bar can show the
    /// capture-armed state (docs/14 UX-08A).
    var onShowingChanged: (() -> Void)?

    /// Brings the capture island back, on the spot the recorder's bar was.
    var onBackToIsland: ((NSRect?) -> Void)?

    /// Leaves the recorder for the capture island rather than closing everything.
    func goBack() {
        let frame = bar.screenFrame
        stage.dismiss()
        composer.hide()
        model.onCameraPreview(false)
        bar.dismissPicker(fading: true)
        onShowingChanged?()
        onBackToIsland?(frame)
    }

    func toggle() {
        if isShowing {
            model.cancel()
        } else {
            present()
        }
    }

    /// - Parameter source: the All-in-One island's glass, when Record was picked there;
    ///   the bar grows out of it rather than appearing on its own.
    func present(picking: RecordTargetKind? = nil, morphingFrom source: NSRect? = nil) {
        wireSession()
        // Opened from the capture island: offer the way back there instead of only Close.
        model.canGoBack = source != nil
        model.refreshDevices()
        model.armedTarget = nil
        model.armDefaultScreenIfNeeded()
        switch picking {
        case .window:
            model.requestWindowPick()
        case .area:
            model.requestAreaPick()
        case .screen, .none:
            revealIsland(morphingFrom: source)
        }
        onShowingChanged?()
    }

    func dismiss() {
        stage.dismiss()
        composer.hide()
        model.onCameraPreview(false)
        bar.dismissPicker()
        onShowingChanged?()
    }

    private func wireSession() {
        model.onHideForPick = { [weak self] in
            self?.stage.dismiss()
            self?.composer.hide()
            self?.bar.dismissPicker()
            self?.onShowingChanged?()
        }
        model.onRevealAfterPick = { [weak self] in
            self?.revealIsland()
            self?.stageArmedArea()
            self?.onShowingChanged?()
        }
        model.onArmedTargetChanged = { [weak self] target in
            if case .area = target {
                return
            }
            self?.stage.dismiss()
        }
        stage.onStart = { [weak self] in self?.model.record() }
        // Backing out of the stage drops the area, not the whole recorder: the island is
        // still there, armed on the screen again, for another choice.
        stage.onCancel = { [weak self] in
            self?.model.armedTarget = nil
            self?.model.armDefaultScreenIfNeeded()
        }
        // Record keeps the bar up: the countdown claims it synchronously and morphs the
        // picker in place. Tearing it down first made a second window pop up elsewhere.
        model.onCommit = { [weak self] in
            // The recording's own highlight takes the dim over from here.
            self?.stage.dismiss()
            self?.composer.hide()
            self?.model.onCameraPreview(false)
        }
        // Only closes a picker nothing took over (control bar off, or the start refused).
        model.onCommitted = { [weak self] in
            self?.bar.dismissPicker()
            self?.onShowingChanged?()
        }
        model.onCancel = { [weak self] in self?.dismiss() }
        model.onBack = { [weak self] in self?.goBack() }
        model.onTeleprompterComposer = { [weak self] in
            guard let self else { return }
            composer.toggle(settings: model.settings, above: bar.screenFrame)
        }
    }

    private func stageArmedArea() {
        guard case let .area(rect, display) = model.armedTarget else { return }
        stage.present(region: rect, displayID: display, purpose: .recording)
    }

    private func revealIsland(morphingFrom source: NSRect? = nil) {
        bar.showPicker(model: model, morphingFrom: source)
        if model.settings.recordingShowsWebcam,
           CaptureMediaAccess.status(for: .camera) == .allowed {
            model.onCameraPreview(true)
        }
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

/// The target the island will record when the user presses Record.
enum RecordArmedTarget: Equatable {
    case screen(CGDirectDisplayID)
    case window(id: CGWindowID, title: String)
    case area(DisplayRect, display: CGDirectDisplayID)
}

@MainActor
@Observable
final class RecordSetupModel {
    let settings: AppSettings
    var displays: [RecordingDeviceCatalog.Display] = []
    var cameras: [RecordingDeviceCatalog.Device] = []
    var microphones: [RecordingDeviceCatalog.Device] = []
    var armedTarget: RecordArmedTarget? {
        didSet { onArmedTargetChanged(armedTarget) }
    }

    /// Lets the HUD drop the staged area as soon as something else is armed.
    @ObservationIgnored var onArmedTargetChanged: (RecordArmedTarget?) -> Void = { _ in }

    @ObservationIgnored let recordAction: (RecordingTarget) -> Void
    /// Hides the island so the selection overlay can own the screen.
    @ObservationIgnored var onHideForPick: () -> Void = {}
    /// Brings the island back after a window or area pick (or a cancel).
    @ObservationIgnored var onRevealAfterPick: () -> Void = {}
    /// The island is done — Record was pressed, countdown owns the bar.
    @ObservationIgnored var onCommit: () -> Void = {}
    /// After the record action ran — the recording has had its chance to claim the bar.
    @ObservationIgnored var onCommitted: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    /// Back to the capture island, when the recorder was opened from it.
    @ObservationIgnored var onBack: () -> Void = {}
    /// Whether the recorder came from the capture island and so shows a back button.
    var canGoBack = false
    /// Turns the live camera bubble on or off. Kept independent of the bar so Area and
    /// Window selection can hide the picker without tearing the session down.
    @ObservationIgnored var onCameraPreview: (Bool) -> Void = { _ in }
    @ObservationIgnored var onPickWindow: (@escaping (WindowSelection?) -> Void) -> Void = { $0(nil) }
    @ObservationIgnored var onPickArea: (@escaping (SelectionResult?) -> Void) -> Void = { $0(nil) }
    /// Opens the script editor that belongs on the bar, not in Settings.
    @ObservationIgnored var onTeleprompterComposer: () -> Void = {}
    var accessPrompt: CaptureAccessKind?
    var accessResume: CaptureAccessResume?
    var accessRequestInFlight = false

    init(settings: AppSettings, record: @escaping (RecordingTarget) -> Void) {
        self.settings = settings
        recordAction = record
    }

    func refreshDevices() {
        displays = RecordingDeviceCatalog.displays()
        cameras = RecordingDeviceCatalog.cameras()
        microphones = RecordingDeviceCatalog.microphones()
    }

    func armDefaultScreenIfNeeded() {
        guard armedTarget == nil else { return }
        armScreen(displays.first?.displayID ?? CGMainDisplayID())
    }

    func armScreen(_ displayID: CGDirectDisplayID) {
        armedTarget = .screen(displayID)
    }

    func isArmed(_ kind: RecordTargetKind) -> Bool {
        switch (armedTarget, kind) {
        case (.screen, .screen), (.window, .window), (.area, .area):
            true
        default:
            false
        }
    }

    var recordingTarget: RecordingTarget? {
        switch armedTarget {
        case let .screen(id):
            .display(id)
        case let .window(id, _):
            .window(id)
        case let .area(rect, display):
            .region(rect, display: display)
        case .none:
            nil
        }
    }

    func requestWindowPick() {
        onHideForPick()
        onPickWindow { [weak self] selection in
            guard let self else { return }
            if let selection {
                let title = selection.window.title?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (title?.isEmpty == false ? title : nil)
                    ?? selection.window.applicationName
                    ?? "Window"
                armedTarget = .window(id: selection.window.id, title: name)
            }
            onRevealAfterPick()
        }
    }

    func requestAreaPick() {
        onHideForPick()
        onPickArea { [weak self] result in
            guard let self else { return }
            if let result {
                armedTarget = .area(result.rect, display: result.display.displayID)
            }
            onRevealAfterPick()
        }
    }

    func record() {
        recordAfterAccessCheck()
    }

    func cancel() {
        onCameraPreview(false)
        onCancel()
    }

    func goBack() {
        onBack()
    }

    /// Escape steps back one level: to the island if the recorder came from there.
    func escape() {
        if canGoBack {
            goBack()
        } else {
            cancel()
        }
    }
}
