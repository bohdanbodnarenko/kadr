import AppKit
import OverlayKit
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
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = NonActivatingPanel(contentRect: hosting.frame, level: .floating)
        panel.contentView = hosting
        panel.setFrame(Self.centeredFrame(for: hosting.fittingSize), display: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        CaptureExclusionRegistry.shared.register(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        self.hosting = hosting
    }

    func dismiss() {
        guard let panel else { return }
        CaptureExclusionRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        hosting = nil
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
        case .area: "Area"
        case .window: "Window"
        case .screen: "Screen"
        case .record: "Record"
        case .gif: "GIF"
        case .scrolling: "Scrolling"
        case .ocr: "Text"
        case .color: "Colour"
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
        case .area: "Drag to capture a region (A)"
        case .window: "Click a window to capture it (W)"
        case .screen: "Capture the whole display (F)"
        case .record: "Open the recorder (R)"
        case .gif: "Record a region, then export GIF (G)"
        case .scrolling: "Capture a scrolling region (S)"
        case .ocr: "Select text and copy it (T)"
        case .color: "Pick a colour from the screen (P)"
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

    private static let timerOptions = [0, 3, 5, 10]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AllInOneMode.allCases, id: \.self) { mode in
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

            RecordingBarDivider()
            timerMenu

            RecordingBarCircleButton(symbol: "xmark", help: "Close (Esc)") {
                model.cancel()
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RecordingBarBackground())
        .padding(10)
        .fixedSize()
        .focusable()
        .onExitCommand { model.cancel() }
        .onKeyPress { press in
            handleKey(press)
        }
        .accessibilityLabel("All-in-One capture")
        .accessibilityHint("Pick a capture mode, or press Return for the last one.")
    }

    private var timerMenu: some View {
        Menu {
            ForEach(Self.timerOptions, id: \.self) { seconds in
                Button(seconds == 0 ? "No delay" : "\(seconds) seconds") {
                    model.settings.customTimerSeconds = 0
                    model.settings.selfTimer = SelfTimer(rawValue: seconds) ?? .off
                }
            }
        } label: {
            RecordingBarIcon(
                symbol: model.settings.timerSeconds > 0 ? "timer" : "timer",
                isOn: model.settings.timerSeconds > 0
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(timerHelp)
        .accessibilityLabel("Self-timer")
        .accessibilityValue(
            model.settings.timerSeconds > 0
                ? "\(model.settings.timerSeconds) seconds"
                : "Off"
        )
    }

    private var timerHelp: String {
        let seconds = model.settings.timerSeconds
        if seconds == 0 {
            return "Self-timer off — wait before capturing hover states"
        }
        return "Self-timer \(seconds)s — click to change"
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
