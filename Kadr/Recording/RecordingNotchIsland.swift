import RecordingCore
import SettingsKit
import SwiftUI

/// Recording controls that grow out of the MacBook notch (macos-notch-ui).
///
/// The shell is flush with the top of the display at menu-bar height. A black band over
/// the camera is not hit-testable; every button sits in the left or right ear.
struct RecordingNotchIsland: View {
    @Bindable var model: RecordingControlBarModel
    @State private var isConfirmingCancel = false
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        let layout = model.notchLayout
        let shape = layout.notchShape
        HStack(spacing: 0) {
            Color.clear
                .frame(width: layout.islandLeadingInset)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                wingContent(layout: layout, side: .leading)
                    .padding(.leading, RecordingNotchLayout.endInset)
                    .padding(.trailing, RecordingNotchLayout.cameraSidePad)
                    .frame(width: layout.leftWingWidth, alignment: .trailing)

                Color.black
                    .frame(width: layout.cameraReserveWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                wingContent(layout: layout, side: .trailing)
                    .padding(.leading, RecordingNotchLayout.cameraSidePad)
                    .padding(.trailing, RecordingNotchLayout.endInset)
                    .frame(width: layout.rightWingWidth, alignment: .leading)
            }
            .foregroundStyle(.white)
            .frame(width: layout.islandWidth, height: layout.shellHeight)
            .background(shape.fill(.black))
            .clipShape(shape)
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .compositingGroup()
        .kadrAnimation(.spring(response: 0.28, dampingFraction: 0.88), value: layout.islandWidth)
        .kadrAnimation(.spring(response: 0.28, dampingFraction: 0.88), value: layout.islandLeadingInset)
        .kadrAnimation(.spring(response: 0.28, dampingFraction: 0.88), value: model.notchVisible)
        .onExitCommand {
            if model.preRoll != nil {
                model.preRoll?.cancel()
            }
        }
        .ignoresSafeArea()
        .onHover { hovering in
            collapseTask?.cancel()
            if hovering {
                model.notchExpanded = true
            } else {
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled else { return }
                    model.notchExpanded = false
                }
            }
        }
        .onDisappear {
            collapseTask?.cancel()
        }
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

    private enum WingSide {
        case leading
        case trailing
    }

    @ViewBuilder
    private func wingContent(layout: RecordingNotchLayout, side: WingSide) -> some View {
        if let preRoll = model.preRoll, let settings = model.settings {
            preRollWing(preRoll: preRoll, settings: settings, side: side)
        } else {
            liveWing(layout: layout, side: side)
        }
    }

    private func liveWing(layout: RecordingNotchLayout, side: WingSide) -> some View {
        HStack(spacing: 6) {
            switch side {
            case .leading:
                statusDot
                Text(model.elapsedText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .accessibilityLabel("Recording time")

                if layout.isExpanded {
                    RecordingAudioMeter(level: model.audioLevel, compact: true)

                    if model.microphoneIsSilent {
                        Label("Mic", systemImage: "mic.slash.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                            .accessibilityLabel("Microphone is silent")
                    }
                }

                notchMoreButton

            case .trailing:
                notchCircleButton(
                    symbol: model.isPaused ? "play.fill" : "pause.fill",
                    help: model.isPaused ? "Resume" : "Pause"
                ) {
                    model.togglePause()
                }
                .accessibilityLabel(model.isPaused ? "Resume recording" : "Pause recording")

                notchFilledButton(
                    symbol: "stop.fill",
                    help: "Stop and keep the recording (⌃⇧.)"
                ) {
                    model.stop()
                }
                .accessibilityLabel("Stop and save")
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(model.isPaused ? Color.orange : Color.red)
            .frame(width: 7, height: 7)
            .opacity(model.isPaused ? 0.45 : 1)
            .accessibilityLabel(model.isPaused ? "Paused" : "Recording")
    }

    private func preRollWing(
        preRoll: RecordingControlBar.PreRoll,
        settings: AppSettings,
        side: WingSide
    ) -> some View {
        HStack(spacing: 6) {
            switch side {
            case .leading:
                Text("\(max(preRoll.remaining, 1))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, alignment: .center)
                    .contentTransition(.numericText(countsDown: true))
                    .accessibilityLabel("Starting in \(preRoll.remaining) seconds")

                notchCircleButton(
                    symbol: settings.recordsMicrophone ? "mic.fill" : "mic.slash.fill",
                    help: settings.recordsMicrophone ? "Microphone is on" : "Microphone is off",
                    isOn: settings.recordsMicrophone
                ) {
                    settings.recordsMicrophone.toggle()
                }
                .disabled(!RecordingOptions.microphoneIsAvailable)
                .accessibilityLabel("Microphone")
                .accessibilityValue(settings.recordsMicrophone ? "On" : "Off")

                notchCircleButton(
                    symbol: settings.recordsSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    help: settings.recordsSystemAudio ? "System sound is on" : "System sound is off",
                    isOn: settings.recordsSystemAudio
                ) {
                    settings.recordsSystemAudio.toggle()
                }
                .accessibilityLabel("System sound")
                .accessibilityValue(settings.recordsSystemAudio ? "On" : "Off")

                notchCircleButton(
                    symbol: settings.recordingShowsWebcam ? "video.fill" : "video.slash.fill",
                    help: settings.recordingShowsWebcam ? "Camera is on" : "Camera is off",
                    isOn: settings.recordingShowsWebcam
                ) {
                    settings.recordingShowsWebcam.toggle()
                }
                .accessibilityLabel("Camera")
                .accessibilityValue(settings.recordingShowsWebcam ? "On" : "Off")

            case .trailing:
                notchFilledButton(symbol: "play.fill", help: "Skip countdown and start now") {
                    preRoll.startNow()
                }
                .accessibilityLabel("Start now")

                notchCircleButton(symbol: "xmark", help: "Cancel") {
                    preRoll.cancel()
                }
                .accessibilityLabel("Cancel countdown")
            }
        }
    }

    private func notchCircleButton(
        symbol: String,
        help: String,
        isOn: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? .white : .white.opacity(0.45))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func notchFilledButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.red))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var notchMoreButton: some View {
        Menu {
            Button("Restart recording") { model.restart() }
            Button("Discard recording", role: .destructive) { isConfirmingCancel = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .menuStyle(.borderlessButton)
        .help("More recording actions")
        .accessibilityLabel("More recording actions")
    }
}
