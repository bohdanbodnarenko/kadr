import AppKit
import SwiftUI

/// Recording controls that grow out of the MacBook notch (macos-notch-ui).
///
/// Two states, one shape. Compact is menu-bar height: a status dot in the left ear and the
/// clock in the right, nothing under the camera. Hovering (or a countdown, or VoiceOver)
/// expands the shell downward and the controls appear in a row *below* the camera housing.
///
/// There is deliberately no black element but the shell's own fill. The previous layout put
/// a solid camera band between two fixed-width wings; whenever a wing's contents were wider
/// than its estimate they slid under that band and disappeared.
struct RecordingNotchIsland: View {
    @Bindable var model: RecordingControlBarModel
    @State private var tooltip = RecordingBarTooltipModel()
    @State private var collapseTask: Task<Void, Never>?
    /// True for the instant after recording begins, which is what the shell stretches on.
    @State private var isActivating = false
    @State private var activationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Leaving the shell for a moment — overshooting a control — must not snap it shut.
    private static let collapseDelay = Duration.milliseconds(350)
    /// How long the activation stretch is held before it settles back.
    private static let activationHold = Duration.milliseconds(90)

    var body: some View {
        let layout = model.notchLayout
        let shape = layout.shape
        shell(layout: layout)
            .frame(minWidth: layout.minimumShellWidth, alignment: .top)
            .overlay(alignment: .top) { ears(layout: layout) }
            .background(shape.fill(Color.black))
            .clipShape(shape)
            // Only once it hangs over content: a compact shell is part of the notch.
            .shadow(color: .black.opacity(layout.showsRow ? 0.35 : 0), radius: 14, y: 6)
            .coordinateSpace(.named(RecordingBarCoordinateSpace.bar))
            .overlay { RecordingBarTooltipLayer(tooltip: tooltip, edge: .bottom) }
            .background { RecordingNotchHoverTracking { setHovering($0) } }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(RecordingBarCoordinateSpace.panel))
            } action: { frame in
                model.barFrameInPanel = frame
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recording controls")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(.named(RecordingBarCoordinateSpace.panel))
            .environment(tooltip)
            .environment(\.colorScheme, .dark)
            // The shell is the mass and the content is what lands in it: two springs, the
            // second a beat behind (`RecordingNotchMorph`).
            .animation(RecordingNotchMorph.shell(reduceMotion: reduceMotion), value: layout.showsRow)
            .animation(RecordingNotchMorph.shell(reduceMotion: reduceMotion), value: layout.isVisible)
            // Sideways only, anchored on the housing: the top edge is the display's edge,
            // and lifting it off shows a line of wallpaper where the camera should be.
            .scaleEffect(
                x: RecordingNotchMorph.stretch(isStretching: isActivating, reduceMotion: reduceMotion),
                y: 1,
                anchor: .top
            )
            .animation(RecordingNotchMorph.activation(reduceMotion: reduceMotion), value: isActivating)
            .ignoresSafeArea()
            .onChange(of: model.preRoll == nil) { _, recording in
                guard recording, layout.isVisible else { return }
                stretchOnce()
            }
            .onDisappear {
                collapseTask?.cancel()
                activationTask?.cancel()
            }
    }

    // MARK: - Shell

    /// The strip over the camera, and the control row below it when expanded.
    private func shell(layout: RecordingNotchLayout) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: layout.stripWidth, height: layout.hardware.height)

            if layout.showsRow {
                row
                    .fixedSize()
                    .frame(height: RecordingNotchLayout.rowHeight)
                    .padding(.top, RecordingNotchLayout.rowTopGap)
                    .padding(.bottom, RecordingNotchLayout.rowBottomPadding)
                    .padding(.horizontal, layout.shape.topCornerRadius + RecordingNotchLayout.rowSidePadding)
                    // In with the shape, out at once: a fading row would hold the height
                    // open while the shell is trying to close.
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                            removal: .identity
                        )
                    )
                    .animation(RecordingNotchMorph.content(reduceMotion: reduceMotion), value: layout.showsRow)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var row: some View {
        if let preRoll = model.preRoll, let settings = model.settings {
            RecordingPreRollBar(preRoll: preRoll, settings: settings, showsCountdown: false)
        } else {
            RecordingLiveControls(model: model, showsClock: false)
        }
    }

    // MARK: - Ears

    /// Status either side of the camera. Overlaid on the finished shell so the ears hug its
    /// outer edges in both states; never hit-testable, so they cannot shadow a control.
    private func ears(layout: RecordingNotchLayout) -> some View {
        HStack(spacing: 0) {
            statusEar
            Spacer(minLength: layout.hardware.width)
            clockEar
        }
        .padding(.horizontal, layout.earPadding)
        .frame(height: layout.hardware.height)
        .foregroundStyle(.white)
        .opacity(layout.isVisible ? 1 : 0)
        .animation(RecordingNotchMorph.content(reduceMotion: reduceMotion), value: layout.isVisible)
        .allowsHitTesting(false)
    }

    private var statusEar: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.preRoll == nil ? RecordingBarMetrics.recordTint : Color.orange)
                .frame(width: 8, height: 8)
                .opacity(model.isPaused ? 0.35 : 1)

            if model.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            } else if model.preRoll == nil {
                // The one thing about a recording in progress worth a glance: whether
                // anything is reaching the microphone.
                RecordingNotchWaveform(
                    meter: model.meter,
                    isResting: model.microphoneIsSilent,
                    tint: model.microphoneIsSilent ? .orange : .white
                )
            }

            if model.microphoneIsSilent, model.preRoll == nil {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusLabel)
    }

    private var clockEar: some View {
        Text(clockText)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText(countsDown: model.preRoll != nil))
            .accessibilityLabel(clockLabel)
    }

    private var clockText: String {
        guard let preRoll = model.preRoll else { return model.elapsedText }
        return "\(max(preRoll.remaining, 1))"
    }

    private var statusLabel: String {
        if model.preRoll != nil {
            return KadrText.string("Countdown")
        }
        if model.microphoneIsSilent {
            return KadrText.string("Recording — microphone is silent")
        }
        return model.isPaused ? KadrText.string("Paused") : KadrText.string("Recording")
    }

    private var clockLabel: String {
        guard let preRoll = model.preRoll else { return "\(model.elapsedText) elapsed" }
        return "Starting in \(max(preRoll.remaining, 1)) seconds"
    }

    /// One stretch when a recording begins, then let it settle.
    private func stretchOnce() {
        activationTask?.cancel()
        isActivating = true
        activationTask = Task { @MainActor in
            try? await Task.sleep(for: Self.activationHold)
            guard !Task.isCancelled else { return }
            isActivating = false
        }
    }

    // MARK: - Hover

    private func setHovering(_ hovering: Bool) {
        collapseTask?.cancel()
        if hovering {
            model.notchExpanded = true
            return
        }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: Self.collapseDelay)
            guard !Task.isCancelled else { return }
            model.notchExpanded = false
        }
    }
}

/// Enter/exit for the whole shell. An AppKit tracking area marked `.activeAlways`, because
/// `.onHover` is silent in a non-activating panel while another app is active — which is
/// the whole time something is being recorded. No cursor of its own; the controls own that.
private struct RecordingNotchHoverTracking: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> RecordingNotchHoverView {
        let view = RecordingNotchHoverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: RecordingNotchHoverView, context: Context) {
        view.onChange = onChange
    }
}

final class RecordingNotchHoverView: NSView {
    var onChange: ((Bool) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onChange?(false)
    }
}
