import AppKit
import OverlayKit
import RecordingCore
import SettingsKit
import Shared
import SwiftUI

/// The All-in-One capture strip (docs/03 §1.4, CleanShot §5).
///
/// One shortcut, one compact HUD, then a mode. Hotkeys stay the fast path; this is the
/// discoverable one — and the thing Option-click on the menu bar extra opens.
///
/// Its own panel, not the recording bar: mixing the two meant starting a recording from
/// here tore down a stills HUD, and the other way around left the recorder looking like
/// a screenshot tool. Destroyed when idle (PRD §8).
@MainActor
final class AllInOneHUD {
    private var panel: NonActivatingPanel?
    private var hosting: NSHostingView<AllInOneView>?
    private let model: AllInOneModel

    init(
        settings: AppSettings,
        perform: @escaping (AllInOneMode) -> Void
    ) {
        model = AllInOneModel(settings: settings, perform: perform)
    }

    var isShowing: Bool {
        panel != nil
    }

    /// Fired when the HUD appears or goes away, so the menu bar can show the armed state.
    var onShowingChanged: (() -> Void)?

    func toggle() {
        if isShowing {
            dismiss()
        } else {
            present()
        }
    }

    func present() {
        model.onCancel = { [weak self] in self?.dismiss() }
        model.onPicked = { [weak self] in self?.dismiss() }

        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: AllInOneView(model: model))
        hosting.sizingOptions = .intrinsicContentSize
        let size = RecordingBarMetrics.resolvedIslandSize(fitting: hosting.fittingSize)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NonActivatingPanel(contentRect: hosting.frame, level: .floating)
        panel.contentView = hosting
        panel.setFrame(Self.centeredFrame(for: size), display: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        CaptureExclusionRegistry.shared.register(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        self.hosting = hosting
        onShowingChanged?()
    }

    func dismiss() {
        guard let panel else { return }
        CaptureExclusionRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        hosting = nil
        onShowingChanged?()
    }

    /// Bottom-centre of the active screen, clear of the menu bar and most window chrome.
    private static func centeredFrame(for size: CGSize) -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let margin: CGFloat = 22
        let x = visible.midX - size.width / 2
        let y = visible.minY + margin
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// What the All-in-One strip can start (docs/03 §1.4).
nonisolated enum AllInOneMode: String, CaseIterable, Sendable {
    case area
    case window
    case screen
    case record
    case gif
    case scrolling
    case ocr
    case color

    var title: String {
        switch self {
        case .area: KadrText.string("Area")
        case .window: KadrText.string("Window")
        case .screen: KadrText.string("Screen")
        case .record: KadrText.string("Record")
        case .gif: KadrText.string("GIF")
        case .scrolling: KadrText.string("Scrolling")
        case .ocr: KadrText.string("Text")
        case .color: KadrText.string("Colour")
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "menubar.rectangle"
        case .record: "record.circle"
        case .gif: "square.stack"
        case .scrolling: "arrow.up.and.down"
        case .ocr: "text.viewfinder"
        case .color: "eyedropper"
        }
    }

    var help: String {
        switch self {
        case .area: KadrText.string("Drag to capture a region (A)")
        case .window: KadrText.string("Click a window to capture it (W)")
        case .screen: KadrText.string("Capture the whole display (F)")
        case .record: KadrText.string("Open the recorder (R)")
        case .gif: KadrText.string("Record a region, then export GIF (G)")
        case .scrolling: KadrText.string("Capture a scrolling region (S)")
        case .ocr: KadrText.string("Select text and copy it (T)")
        case .color: KadrText.string("Pick a colour from the screen (P)")
        }
    }

    /// Single-key shortcut while the HUD is key (CleanShot 4.8).
    var shortcut: Character {
        switch self {
        case .area: "a"
        case .window: "w"
        case .screen: "f"
        case .record: "r"
        case .gif: "g"
        case .scrolling: "s"
        case .ocr: "t"
        case .color: "p"
        }
    }

    static func matching(shortcut raw: String) -> AllInOneMode? {
        guard let character = raw.lowercased().first else { return nil }
        return allCases.first { $0.shortcut == character }
    }
}

@MainActor
@Observable
final class AllInOneModel {
    let settings: AppSettings
    @ObservationIgnored private let perform: (AllInOneMode) -> Void
    @ObservationIgnored var onPicked: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}

    init(settings: AppSettings, perform: @escaping (AllInOneMode) -> Void) {
        self.settings = settings
        self.perform = perform
    }

    var lastMode: AllInOneMode {
        AllInOneMode(rawValue: settings.lastAllInOneMode) ?? .area
    }

    func pick(_ mode: AllInOneMode) {
        settings.lastAllInOneMode = mode.rawValue
        onPicked()
        perform(mode)
    }

    func pickLast() {
        pick(lastMode)
    }

    func cancel() {
        onCancel()
    }
}

struct AllInOneView: View {
    @Bindable var model: AllInOneModel

    private static let presetTimerOptions = [0, 3, 5, 10]
    private static let primaryModes: [AllInOneMode] = [.area, .window, .screen, .record]
    private static let overflowModes: [AllInOneMode] = [.gif, .scrolling, .ocr, .color]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullStrip
            twoRowStrip
            compactStrip
        }
        .recordingIslandSurface()
        .focusable()
        .onExitCommand { model.cancel() }
        .onKeyPress { press in
            handleKey(press)
        }
        .accessibilityLabel("All-in-One capture")
        .accessibilityHint("Pick a capture mode, or press Return for the last one.")
        .kadrLayoutDirection()
    }

    private var fullStrip: some View {
        HStack(spacing: RecordingBarMetrics.controlSpacing) {
            modeButtons(for: AllInOneMode.allCases)
            RecordingBarDivider()
            timerMenu
            aspectMenu
            saveTargetMenu
            recordingAudioMenu
            closeButton
        }
    }

    private var twoRowStrip: some View {
        VStack(spacing: RecordingBarMetrics.controlSpacing) {
            HStack(spacing: RecordingBarMetrics.controlSpacing) {
                modeButtons(for: Self.primaryModes)
                overflowMenu
                Spacer(minLength: 0)
                closeButton
            }
            HStack(spacing: RecordingBarMetrics.controlSpacing) {
                timerMenu
                aspectMenu
                saveTargetMenu
                recordingAudioMenu
                Spacer(minLength: 0)
            }
        }
    }

    private var compactStrip: some View {
        HStack(spacing: RecordingBarMetrics.controlSpacing) {
            modeButtons(for: Self.primaryModes)
            overflowMenu
            RecordingBarDivider()
            optionsMenu
            closeButton
        }
    }

    private func modeButtons(for modes: [AllInOneMode]) -> some View {
        ForEach(modes, id: \.self) { mode in
            modeButton(mode)
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(Self.overflowModes, id: \.self) { mode in
                Button(mode.title) { model.pick(mode) }
            }
        } label: {
            RecordingBarIcon(symbol: "ellipsis.circle")
        }
        .recordingBarMenu(tooltip: "More capture modes")
        .accessibilityLabel("More capture modes")
    }

    private func modeButton(_ mode: AllInOneMode) -> some View {
        RecordingBarCircleButton(
            symbol: mode.symbol,
            help: mode.help,
            isOn: true,
            tint: mode == model.lastMode ? Color.accentColor : nil
        ) {
            model.pick(mode)
        }
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(mode == model.lastMode ? .isSelected : [])
    }

    private var closeButton: some View {
        RecordingBarCircleButton(symbol: "xmark", help: "Close (Esc)") {
            model.cancel()
        }
        .accessibilityLabel("Close")
    }

    var timerOptions: [Int] {
        var options = Self.presetTimerOptions
        let custom = model.settings.customTimerSeconds
        if custom > 0, !options.contains(custom) {
            options.append(custom)
            options.sort()
        }
        return options
    }

    private var timerMenu: some View {
        Menu {
            ForEach(timerOptions, id: \.self) { seconds in
                Button(timerLabel(seconds)) {
                    if seconds == model.settings.customTimerSeconds, seconds > 0 {
                        model.settings.selfTimer = .off
                    } else {
                        model.settings.customTimerSeconds = 0
                        model.settings.selfTimer = SelfTimer(rawValue: seconds) ?? .off
                    }
                }
            }
        } label: {
            RecordingBarIcon(
                symbol: "timer",
                isOn: model.settings.timerSeconds > 0
            )
        }
        .recordingBarMenu(tooltip: timerHelp)
        .accessibilityLabel("Self-timer")
        .accessibilityValue(
            model.settings.timerSeconds > 0
                ? "\(model.settings.timerSeconds) seconds"
                : "Off"
        )
    }

    private var aspectMenu: some View {
        Menu {
            ForEach(CaptureSelectionAspect.allCases, id: \.self) { aspect in
                Button(aspect.title) {
                    model.settings.captureSelectionAspect = aspect
                }
            }
        } label: {
            RecordingBarIcon(
                symbol: model.settings.captureSelectionAspect == .free
                    ? "aspectratio"
                    : "lock.rectangle",
                isOn: model.settings.captureSelectionAspect != .free
            )
        }
        .recordingBarMenu(tooltip: aspectHelp)
        .accessibilityLabel("Aspect lock")
        .accessibilityValue(model.settings.captureSelectionAspect.title)
    }

    private var aspectHelp: String {
        let aspect = model.settings.captureSelectionAspect
        if aspect == .free {
            return "Aspect unlocked — ⇧-drag still squares the selection"
        }
        return "Aspect \(aspect.title) — click to change"
    }

    private var timerHelp: String {
        let seconds = model.settings.timerSeconds
        if seconds == 0 {
            return "Self-timer off — wait before capturing hover states"
        }
        return "Self-timer \(seconds)s — click to change"
    }

    func timerLabel(_ seconds: Int) -> String {
        if seconds == 0 {
            return "No delay"
        }
        if seconds == model.settings.customTimerSeconds, seconds > 0 {
            return "Custom: \(seconds)s"
        }
        return "\(seconds) seconds"
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .return || press.key == .space {
            model.pickLast()
            return .handled
        }
        if let mode = AllInOneMode.matching(shortcut: press.characters) {
            model.pick(mode)
            return .handled
        }
        return .ignored
    }
}
