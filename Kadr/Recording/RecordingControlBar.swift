import AppKit
import OverlayKit
import RecordingCore
import SettingsKit
import Shared
import SwiftUI

/// The floating controls shown before and during a recording (docs/03 §1.8, docs/08 §2).
///
/// One panel, three modes. The picker, the countdown strip and the live Stop/Pause bar
/// used to be three different windows that appeared and vanished independently, so starting
/// a recording meant watching a card disappear and a different capsule pop up somewhere
/// nearby. They now share this panel: picking a display morphs the icons into the clock,
/// and only Area/Window hide it (the selection overlay has to own the screen).
///
/// A non-activating panel, for the same reason the scrolling-capture HUD is one: the user
/// is recording whatever is behind this, and a bar that stole focus would change the thing
/// being filmed. It registers with `CaptureExclusionRegistry`, so it never appears in the
/// recording it controls.
///
/// Destroyed when idle — no window, no view, no timer (PRD §8).
@MainActor
final class RecordingControlBar {
    private var panel: NonActivatingPanel?
    private var hosting: NSHostingView<RecordingControlBarView>?
    private let model = RecordingControlBarModel()

    /// Where the user last dragged it, so it comes back where they put it.
    ///
    /// Screen-relative and re-clamped on show: a bar remembered on a display that has since
    /// been unplugged has to come back somewhere visible rather than off the desk.
    static var savedOrigin: CGPoint?

    private static let margin: CGFloat = 22

    var isShowing: Bool {
        panel != nil
    }

    /// The bar's frame in screen space, so the teleprompter composer can sit above it.
    var screenFrame: NSRect? {
        panel?.frame
    }

    var isShowingPicker: Bool {
        panel != nil && model.picker != nil && model.session == nil
    }

    func showPicker(model picker: RecordSetupModel) {
        model.picker = picker
        model.session = nil
        model.preRoll = nil
        present(key: true)
    }

    func dismissPicker() {
        guard isShowingPicker else { return }
        dismiss()
    }

    func show(controls: RecordingControls, settings: AppSettings? = nil, preRoll: PreRoll? = nil) {
        model.picker = nil
        model.apply(controls)
        model.settings = settings
        model.preRoll = preRoll
        model.session = true
        present(key: false)
    }

    /// Updates the timer and the paused state without rebuilding anything.
    func update(controls: RecordingControls, settings: AppSettings? = nil, preRoll: PreRoll? = nil) {
        guard panel != nil else { return }
        model.picker = nil
        model.apply(controls)
        model.settings = settings
        model.preRoll = preRoll
        model.session = true
        resizeToFittingSize()
    }

    /// What the bar offers while the countdown is running.
    ///
    /// The three things a recording is usually got wrong by forgetting — microphone, system
    /// sound, camera — were reachable only from Settings, so recording a demo with your
    /// voice meant leaving the thing you were about to record, opening a window, finding a
    /// checkbox and coming back. docs/03 §1.8 asks for a control strip before Record for
    /// exactly this.
    struct PreRoll {
        let remaining: Int
        let startNow: () -> Void
        let cancel: () -> Void
    }

    func dismiss() {
        guard let panel else { return }
        Self.savedOrigin = panel.frame.origin
        CaptureExclusionRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        hosting = nil
        model.picker = nil
        model.session = nil
        model.preRoll = nil
    }

    private func present(key: Bool) {
        if let panel {
            panel.becomesKeyOnlyIfNeeded = !key
            if key {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            resizeToFittingSize()
            return
        }

        let hosting = NSHostingView(rootView: RecordingControlBarView(model: model))
        hosting.sizingOptions = .intrinsicContentSize
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = NonActivatingPanel(contentRect: hosting.frame, level: .floating)
        panel.contentView = hosting
        panel.setFrame(frame(for: hosting.fittingSize), display: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = !key
        CaptureExclusionRegistry.shared.register(panel)
        if key {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.orderFrontRegardless()
        }
        self.panel = panel
        self.hosting = hosting
    }

    private func resizeToFittingSize() {
        guard let panel, let hosting else { return }
        hosting.invalidateIntrinsicContentSize()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        // Keep the centre so a shorter live bar does not jump left when the picker
        // morphs into the clock.
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = size
        frame.origin.x = centre.x - size.width / 2
        frame.origin.y = centre.y - size.height / 2
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? panel.frame
        frame.origin.x = min(
            max(frame.origin.x, visible.minX + Self.margin),
            visible.maxX - size.width - Self.margin
        )
        frame.origin.y = min(
            max(frame.origin.y, visible.minY + Self.margin),
            visible.maxY - size.height - Self.margin
        )
        panel.setFrame(frame, display: true)
    }

    /// Bottom-centre of the active screen by default — where a recording HUD is expected,
    /// and clear of the menu bar and most window chrome.
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

/// What the bar shows, as one observable value the panel can update in place.
@MainActor
@Observable
final class RecordingControlBarModel {
    var elapsedText = "0:00"
    var isPaused = false
    var audioLevel: Float = 0
    var microphoneIsSilent = false
    var picker: RecordSetupModel?
    /// Non-nil once a recording (or its countdown) owns the bar.
    var session: Bool?
    var preRoll: RecordingControlBar.PreRoll?
    var settings: AppSettings?

    @ObservationIgnored var stop: () -> Void = {}
    @ObservationIgnored var togglePause: () -> Void = {}
    @ObservationIgnored var cancel: () -> Void = {}
    @ObservationIgnored var restart: () -> Void = {}

    func apply(_ controls: RecordingControls) {
        elapsedText = controls.elapsedText
        isPaused = controls.isPaused
        audioLevel = controls.audioLevel
        microphoneIsSilent = controls.microphoneIsSilent
        stop = controls.stop
        togglePause = controls.togglePause
        cancel = controls.cancel
        restart = controls.restart
    }
}

struct RecordingControlBarView: View {
    @Bindable var model: RecordingControlBarModel
    @State private var isConfirmingCancel = false

    var body: some View {
        Group {
            if let picker = model.picker, model.session == nil {
                RecordSetupView(model: picker)
            } else if let preRoll = model.preRoll, let settings = model.settings {
                RecordingPreRollBar(preRoll: preRoll, settings: settings)
            } else {
                liveBar
            }
        }
        .animation(.snappy(duration: 0.22), value: model.session != nil)
        .animation(.snappy(duration: 0.22), value: model.preRoll != nil)
    }

    private var liveBar: some View {
        HStack(spacing: 8) {
            statusDot
            Text(model.elapsedText)
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 56, alignment: .leading)
                .accessibilityLabel("Recording time")

            RecordingAudioMeter(level: model.audioLevel)

            if model.microphoneIsSilent {
                Text("Mic silent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("The microphone is on but nothing is reaching it. Check mute and the input.")
                    .accessibilityLabel("Microphone is silent")
            }

            RecordingBarDivider()

            RecordingBarCircleButton(
                symbol: model.isPaused ? "play.fill" : "pause.fill",
                help: model.isPaused ? "Resume" : "Pause"
            ) {
                model.togglePause()
            }
            .accessibilityLabel(model.isPaused ? "Resume recording" : "Pause recording")

            RecordingBarCircleButton(
                symbol: "arrow.counterclockwise",
                help: "Start over — discard what's recorded and record again"
            ) {
                model.restart()
            }
            .accessibilityLabel("Restart recording")

            RecordingBarFilledCircleButton(
                symbol: "stop.fill",
                help: "Stop and keep the recording (⌃⇧.)"
            ) {
                model.stop()
            }
            .accessibilityLabel("Stop and save")

            RecordingBarCircleButton(symbol: "trash", help: "Discard this recording") {
                isConfirmingCancel = true
            }
            .accessibilityLabel("Discard recording")
            .confirmationDialog(
                "Discard this recording?",
                isPresented: $isConfirmingCancel
            ) {
                Button("Discard", role: .destructive) { model.cancel() }
                Button("Keep Recording", role: .cancel) {}
            } message: {
                Text("What you have recorded so far will be deleted.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RecordingBarBackground())
        .padding(10)
        .fixedSize()
        .animation(.snappy(duration: 0.22), value: model.isPaused)
        .animation(.snappy(duration: 0.22), value: model.microphoneIsSilent)
    }

    /// Red and steady while recording, amber while paused.
    ///
    /// Not animated: this sits on screen for the length of a recording, and a pulsing layer
    /// is a repeating animation in the process whose whole design is that it has none.
    private var statusDot: some View {
        Circle()
            .fill(model.isPaused ? Color.orange : Color.red)
            .frame(width: 8, height: 8)
            .opacity(model.isPaused ? 0.45 : 1)
            .padding(.leading, 6)
            .accessibilityLabel(model.isPaused ? "Paused" : "Recording")
    }
}
