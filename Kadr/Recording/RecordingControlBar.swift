import AppKit
import OverlayKit
import RecordingCore
import SettingsKit
import Shared
import SwiftUI

/// The floating controls shown while a recording runs (docs/03 §1.8, docs/08 §2).
///
/// docs/03 asks for "an optional floating stop button" and the app shipped without one, so
/// the only way to stop was the menu-bar dropdown: notice the icon changed, find it among
/// twenty other menu extras, click, read a menu, choose Stop. Four deliberate steps to end
/// something the user is doing *right now*, and no indication anywhere on screen that any
/// of that was possible. The commonest report about the recorder was not knowing how to
/// stop it, which is the most complete way a feature can fail.
///
/// A non-activating panel, for the same reason the scrolling-capture HUD is one: the user
/// is recording whatever is behind this, and a bar that stole focus would change the thing
/// being filmed. It registers with `CaptureExclusionRegistry`, so it never appears in the
/// recording it controls.
///
/// Built when recording starts and destroyed when it stops. Nothing here exists while the
/// agent is idle — no window, no view, no timer (PRD §8).
@MainActor
final class RecordingControlBar {
    private var panel: NonActivatingPanel?
    private let model = RecordingControlBarModel()

    /// Where the user last dragged it, so it comes back where they put it.
    ///
    /// Screen-relative and re-clamped on show: a bar remembered on a display that has since
    /// been unplugged has to come back somewhere visible rather than off the desk.
    private static var savedOrigin: CGPoint?

    private static let margin: CGFloat = 22

    var isShowing: Bool {
        panel != nil
    }

    func show(controls: RecordingControls, settings: AppSettings? = nil, preRoll: PreRoll? = nil) {
        model.apply(controls)
        model.settings = settings
        model.preRoll = preRoll
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: RecordingControlBarView(model: model))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = NonActivatingPanel(contentRect: hosting.frame, level: .floating)
        panel.contentView = hosting
        panel.setFrame(frame(for: hosting.fittingSize), display: false)
        // Follows the user across Spaces: a recording is a global activity, and a bar left
        // behind on Space 1 is a bar that cannot stop the recording running on Space 2.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Dragged by its own background rather than by a SwiftUI gesture: AppKit already
        // moves a window this way, and it keeps the mouse path out of SwiftUI — which the
        // overlay rules ask for and which a gesture competing with the buttons would break.
        // `isMovable` is false on the shared overlay recipe because a selection overlay must
        // not move; this one must.
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        // Key only if a control genuinely needs the keyboard — which none here do.
        //
        // The user is typing into whatever they are recording. A HUD that took key status
        // on the first click would swallow their next keystroke, and on a recording with
        // the keystroke overlay on it would swallow it from the sidecar too, so the video
        // would show a pause exactly where they clicked Pause.
        panel.becomesKeyOnlyIfNeeded = true
        CaptureExclusionRegistry.shared.register(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Updates the timer and the paused state without rebuilding anything.
    func update(controls: RecordingControls, settings: AppSettings? = nil, preRoll: PreRoll? = nil) {
        guard panel != nil else { return }
        model.apply(controls)
        model.settings = settings
        model.preRoll = preRoll
    }

    /// What the bar offers while the countdown is running.
    ///
    /// The three things a recording is usually got wrong by forgetting — microphone, system
    /// sound, camera — were reachable only from Settings, so recording a demo with your
    /// voice meant leaving the thing you were about to record, opening a window, finding a
    /// checkbox and coming back. docs/03 §1.8 asks for a control strip before Record for
    /// exactly this.
    ///
    /// Put in the countdown rather than in a step of its own: the wait already exists, the
    /// user is already looking at the screen, and adding a panel they have to dismiss to
    /// start recording would be a click nobody asked for.
    struct PreRoll {
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
    }

    /// Bottom-centre of the active screen by default — where a recording HUD is expected,
    /// and clear of the menu bar and most window chrome.
    private func frame(for size: CGSize) -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let origin = Self.savedOrigin ?? CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + Self.margin
        )
        // Clamped back onto a screen that still exists.
        let x = min(max(origin.x, visible.minX + Self.margin), visible.maxX - size.width - Self.margin)
        let y = min(max(origin.y, visible.minY + Self.margin), visible.maxY - size.height - Self.margin)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// What the bar shows, as one observable value the panel can update in place.
///
/// A model rather than rebuilding the root view every tick: the elapsed time changes once a
/// second for the length of a recording, and replacing an `NSHostingView`'s root view that
/// often re-creates the whole tree — in the process with the 30 MB budget.
@MainActor
@Observable
final class RecordingControlBarModel {
    var elapsedText = "0:00"
    var isPaused = false

    /// Non-nil while the countdown is running.
    var preRoll: RecordingControlBar.PreRoll?
    /// Bound live so a toggle flipped here is the setting, and is still set next time.
    var settings: AppSettings?

    @ObservationIgnored var stop: () -> Void = {}
    @ObservationIgnored var togglePause: () -> Void = {}
    @ObservationIgnored var cancel: () -> Void = {}

    func apply(_ controls: RecordingControls) {
        elapsedText = controls.elapsedText
        isPaused = controls.isPaused
        stop = controls.stop
        togglePause = controls.togglePause
        cancel = controls.cancel
    }
}

/// Stop, pause and the clock — in that order of prominence.
///
/// Stop is the big red one because stopping is what the user came here to do and could not
/// work out. Cancel is deliberately last and quiet: it throws the recording away, and a
/// discard sitting next to a stop at equal weight is a discard somebody eventually hits by
/// accident.
private struct RecordingControlBarView: View {
    @Bindable var model: RecordingControlBarModel
    @State private var isConfirmingCancel = false

    var body: some View {
        if let preRoll = model.preRoll, let settings = model.settings {
            preRollBar(preRoll: preRoll, settings: settings)
        } else {
            liveBar
        }
    }

    /// Microphone, system sound and camera, while the countdown runs.
    private func preRollBar(preRoll: RecordingControlBar.PreRoll, settings: AppSettings) -> some View {
        HStack(spacing: 8) {
            Text("Starting…")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            Divider().frame(height: 20)

            if RecordingOptions.microphoneIsAvailable {
                toggle(
                    on: Binding(get: { settings.recordsMicrophone }, set: { settings.recordsMicrophone = $0 }),
                    symbol: "mic.fill",
                    off: "mic.slash.fill",
                    label: "Microphone"
                )
            }
            toggle(
                on: Binding(get: { settings.recordsSystemAudio }, set: { settings.recordsSystemAudio = $0 }),
                symbol: "speaker.wave.2.fill",
                off: "speaker.slash.fill",
                label: "System sound"
            )
            toggle(
                on: Binding(get: { settings.recordingShowsWebcam }, set: { settings.recordingShowsWebcam = $0 }),
                symbol: "video.fill",
                off: "video.slash.fill",
                label: "Camera"
            )

            Divider().frame(height: 20)

            Button("Start now") { preRoll.startNow() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            Button("Cancel") { preRoll.cancel() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 10, y: 3)
        .padding(6)
        .fixedSize()
    }

    /// One on/off control that says what it does, rather than a checkbox with a word.
    private func toggle(
        on binding: Binding<Bool>,
        symbol: String,
        off: String,
        label: String
    ) -> some View {
        Button {
            binding.wrappedValue.toggle()
        } label: {
            Image(systemName: binding.wrappedValue ? symbol : off)
                .frame(width: 16)
                .foregroundStyle(binding.wrappedValue ? Color.primary : Color.secondary)
        }
        .help(binding.wrappedValue ? "\(label) is on" : "\(label) is off")
        .accessibilityLabel(label)
        .accessibilityValue(binding.wrappedValue ? "On" : "Off")
    }

    private var liveBar: some View {
        HStack(spacing: 10) {
            statusDot
            Text(model.elapsedText)
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 52, alignment: .leading)
                .accessibilityLabel("Recording time")

            Divider().frame(height: 20)

            Button {
                model.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            // No keyboard shortcut here on purpose: the panel never takes key status, so a
            // shortcut printed on it would be one that does nothing. Stopping from the
            // keyboard is a *global* hotkey (⌃⇧.), which works wherever the user is.
            .help("Stop and keep the recording (⌃⇧.)")

            Button {
                model.togglePause()
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 14)
            }
            .help(model.isPaused ? "Resume" : "Pause")
            .accessibilityLabel(model.isPaused ? "Resume recording" : "Pause recording")

            Button {
                isConfirmingCancel = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Discard this recording")
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 10, y: 3)
        .padding(6)
        .fixedSize()
    }

    /// Red and steady while recording, amber while paused.
    ///
    /// Not animated: this sits on screen for the length of a recording, and a pulsing layer
    /// is a repeating animation in the process whose whole design is that it has none.
    private var statusDot: some View {
        Circle()
            .fill(model.isPaused ? Color.orange : Color.red)
            .frame(width: 11, height: 11)
            .accessibilityLabel(model.isPaused ? "Paused" : "Recording")
    }
}
