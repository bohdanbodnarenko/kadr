import AppKit
import OverlayKit
import RecordingCore
import SettingsKit
import Shared
import SwiftUI

/// Record mode: choose what and how, then start (docs/03 §1.4, §1.8).
///
/// Recording used to begin the instant a hotkey fired. The shortcut chose the target *and*
/// committed to it in one press, so there was no moment at which somebody could look at what
/// was about to happen and change their mind — no way to pick a window, no way to turn the
/// microphone on, no way to back out except stopping a recording that had already started.
///
/// This is that moment. Nothing here records anything: it picks a target, flips the three
/// options a recording is most often ruined by forgetting, and hands over to the countdown
/// only when the user presses Start Recording.
@MainActor
final class RecordSetupHUD {
    private var panel: NonActivatingPanel?
    private let model: RecordSetupModel

    private static let margin: CGFloat = 24

    /// Where the user last left it.
    private static var savedOrigin: CGPoint?

    init(settings: AppSettings, start: @escaping (RecordTargetKind) -> Void) {
        model = RecordSetupModel(settings: settings, start: start)
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
        guard panel == nil else {
            panel?.orderFrontRegardless()
            return
        }
        model.onStart = { [weak self] in self?.dismiss() }
        model.onCancel = { [weak self] in self?.dismiss() }

        let hosting = NSHostingView(rootView: RecordSetupView(model: model))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = NonActivatingPanel(contentRect: hosting.frame, level: .floating)
        panel.contentView = hosting
        panel.setFrame(frame(for: hosting.fittingSize), display: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        // Key, unlike the recording bar: nothing is being recorded yet, so taking the
        // keyboard costs nothing — and Escape has to reach it.
        panel.becomesKeyOnlyIfNeeded = false
        CaptureExclusionRegistry.shared.register(panel)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func dismiss() {
        guard let panel else { return }
        Self.savedOrigin = panel.frame.origin
        CaptureExclusionRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }

    private func frame(for size: CGSize) -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let origin = Self.savedOrigin ?? CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + Self.margin
        )
        let x = min(max(origin.x, visible.minX + Self.margin), visible.maxX - size.width - Self.margin)
        let y = min(max(origin.y, visible.minY + Self.margin), visible.maxY - size.height - Self.margin)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
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
        case .area: "selection.pin.in.out"
        case .window: "macwindow"
        case .screen: "display"
        }
    }

    /// What pressing Start actually does next, said plainly so the button is not a surprise.
    var followUp: String {
        switch self {
        case .area: "You will draw the area next."
        case .window: "You will click the window next."
        case .screen: "Recording starts after the countdown."
        }
    }
}

@MainActor
@Observable
final class RecordSetupModel {
    let settings: AppSettings
    var target: RecordTargetKind = .area

    @ObservationIgnored private let start: (RecordTargetKind) -> Void
    @ObservationIgnored var onStart: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}

    init(settings: AppSettings, start: @escaping (RecordTargetKind) -> Void) {
        self.settings = settings
        self.start = start
    }

    func beginRecording() {
        onStart()
        start(target)
    }

    func cancel() {
        onCancel()
    }
}

/// The HUD itself.
private struct RecordSetupView: View {
    @Bindable var model: RecordSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            targets
            Divider()
            options
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator)
        )
        .shadow(radius: 18, y: 6)
        .padding(8)
        .fixedSize()
        .onExitCommand { model.cancel() }
    }

    /// Area, Window, Screen — as three big targets rather than a menu, because this is the
    /// decision the whole HUD exists for.
    private var targets: some View {
        HStack(spacing: 8) {
            ForEach(RecordTargetKind.allCases) { kind in
                Button {
                    model.target = kind
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 20, weight: .regular))
                        Text(kind.title)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(model.target == kind ? 0.22 : 0.06))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(model.target == kind ? 0.9 : 0))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record \(kind.title)")
                .accessibilityAddTraits(model.target == kind ? .isSelected : [])
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            if RecordingOptions.microphoneIsAvailable {
                Toggle("Microphone", isOn: Binding(
                    get: { model.settings.recordsMicrophone },
                    set: { model.settings.recordsMicrophone = $0 }
                ))
            }
            Toggle("System sound", isOn: Binding(
                get: { model.settings.recordsSystemAudio },
                set: { model.settings.recordsSystemAudio = $0 }
            ))
            Toggle("Camera", isOn: Binding(
                get: { model.settings.recordingShowsWebcam },
                set: { model.settings.recordingShowsWebcam = $0 }
            ))
            Picker("Countdown", selection: Binding(
                get: { model.settings.recordingCountdownSeconds },
                set: { model.settings.recordingCountdownSeconds = $0 }
            )) {
                Text("Off").tag(0)
                Text("3s").tag(3)
                Text("5s").tag(5)
                Text("10s").tag(10)
            }
            .pickerStyle(.segmented)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.target.followUp)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Recording") { model.beginRecording() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
