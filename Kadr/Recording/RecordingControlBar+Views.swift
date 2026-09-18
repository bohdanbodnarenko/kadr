import OverlayKit
import SettingsKit
import SwiftUI

struct RecordingControlBarView: View {
    @Bindable var model: RecordingControlBarModel

    var body: some View {
        Group {
            if model.docksToNotch {
                RecordingNotchIsland(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                RecordingFloatingBar(model: model)
            }
        }
        .kadrLayoutDirection()
        .background(Color.clear)
    }
}

/// The floating island: one glass bar whose contents change with the mode.
private struct RecordingFloatingBar: View {
    @Bindable var model: RecordingControlBarModel
    @State private var tooltip = RecordingBarTooltipModel()

    var body: some View {
        bar
            // The slack above the bar is the tooltip's room, the slack below the shadow's.
            .padding(.bottom, RecordingBarMetrics.shadowSlack)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .coordinateSpace(.named(RecordingBarCoordinateSpace.panel))
            .environment(tooltip)
    }

    private var bar: some View {
        Group {
            switch model.mode {
            case .picker:
                if let picker = model.picker {
                    RecordSetupView(model: picker)
                }
            case .preRoll:
                if let preRoll = model.preRoll, let settings = model.settings {
                    RecordingPreRollBar(preRoll: preRoll, settings: settings)
                }
            case .live:
                RecordingLiveControls(model: model)
            }
        }
        .fixedSize()
        // The outgoing controls leave instantly so the bar starts changing width at once;
        // a fading-out set would hold its width and the bar would bulge to fit both.
        .transition(.asymmetric(insertion: .opacity, removal: .identity))
        .padding(.horizontal, RecordingBarMetrics.horizontalPadding)
        // Arriving from the All-in-One island: the glass starts at that island's size with
        // the controls hidden, then springs to its own while they fade in — one capsule
        // changing shape rather than one window swapped for another.
        .opacity(model.entranceSize == nil ? 1 : 0)
        .frame(
            width: model.entranceSize?.width,
            height: model.entranceSize?.height ?? RecordingBarMetrics.barHeight
        )
        .recordingBarGlass()
        .coordinateSpace(.named(RecordingBarCoordinateSpace.bar))
        .overlay { RecordingBarTooltipLayer(tooltip: tooltip) }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(RecordingBarCoordinateSpace.panel))
        } action: { frame in
            model.barFrameInPanel = frame
        }
    }
}

/// Elapsed time and the transport for the recording that is running.
struct RecordingLiveControls: View {
    @Bindable var model: RecordingControlBarModel
    /// Off in the notch island, whose ear already shows the clock.
    var showsClock = true

    var body: some View {
        HStack(spacing: RecordingBarMetrics.controlSpacing) {
            if showsClock {
                elapsed
            }

            if model.isConfirmingDiscard {
                discardConfirmation
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            } else {
                transport
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .kadrAnimation(RecordingBarMetrics.modeChange, value: model.microphoneIsSilent)
    }

    private var transport: some View {
        HStack(spacing: RecordingBarMetrics.controlSpacing) {
            RecordingLiveAudioMeter(meter: model.meter)
                .padding(.horizontal, 6)

            if model.microphoneIsSilent {
                Text("Mic silent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.trailing, 6)
                    .help("The microphone is on but nothing is reaching it. Check mute and the input.")
                    .accessibilityLabel("Microphone is silent")
            }

            RecordingBarDivider()

            RecordingBarCircleButton(
                symbol: model.isPaused ? "play.fill" : "pause.fill",
                help: model.isPaused ? "Resume recording" : "Pause recording"
            ) {
                model.togglePause()
            }
            .disabled(model.isTransitioning)

            RecordingBarCircleButton(
                symbol: "arrow.counterclockwise",
                help: "Start over"
            ) {
                model.restart()
            }
            .disabled(model.isTransitioning)
            .accessibilityLabel("Restart — discard what's recorded and record again")

            RecordingBarFilledCircleButton(
                symbol: "stop.fill",
                help: "Stop and save (⌃⇧.)"
            ) {
                model.stop()
            }
            .disabled(model.isTransitioning)
            .accessibilityLabel("Stop and save the recording")

            RecordingBarCircleButton(symbol: "trash.fill", help: "Discard recording") {
                setConfirmingDiscard(true)
            }
            .accessibilityLabel("Discard — delete this recording without saving")
        }
    }

    /// Asked in place rather than in a dialog.
    ///
    /// A confirmation dialog is a sheet on this panel: AppKit dims the whole transparent
    /// window behind it, a grey slab around the bar or the notch. A standalone alert would
    /// instead activate Kadr and change what is being recorded. The recording keeps
    /// running meanwhile, so the clock stays.
    private var discardConfirmation: some View {
        HStack(spacing: 8) {
            Text("Discard this recording?")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RecordingBarMetrics.activeTint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)

            Button("Keep Recording") {
                setConfirmingDiscard(false)
            }
            .buttonStyle(RecordingBarCapsuleButtonStyle())

            Button("Discard") {
                model.isConfirmingDiscard = false
                model.cancel()
            }
            .buttonStyle(RecordingBarCapsuleButtonStyle(isDestructive: true))
            .accessibilityHint("What you have recorded so far will be deleted.")
        }
        .padding(.horizontal, 4)
        .frame(height: RecordingBarMetrics.controlSize)
        .help("What you have recorded so far will be deleted.")
        .accessibilityElement(children: .contain)
    }

    private func setConfirmingDiscard(_ confirming: Bool) {
        withAnimation(AccessibilityChrome.animation(RecordingBarMetrics.modeChange)) {
            model.isConfirmingDiscard = confirming
        }
    }

    /// Red and steady while recording, dimmed while paused.
    ///
    /// Not animated: this sits on screen for the length of a recording, and a pulsing layer
    /// is a repeating animation in the process whose whole design is that it has none.
    private var elapsed: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(RecordingBarMetrics.recordTint)
                .frame(width: 8, height: 8)
                .opacity(model.isPaused ? 0.35 : 1)

            Text(model.elapsedText)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(RecordingBarMetrics.activeTint)
                // Fixed width so 9:59 → 10:00 does not nudge the whole bar sideways.
                .frame(minWidth: 56, alignment: .leading)

            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(notice)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: RecordingBarMetrics.controlSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            model.isPaused
                ? "Recording paused at \(model.elapsedText)"
                : "Recording, \(model.elapsedText) elapsed"
        )
    }
}
