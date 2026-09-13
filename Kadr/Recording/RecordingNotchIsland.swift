import RecordingCore
import SettingsKit
import SwiftUI

/// Live recording controls clipped to the camera-notch island.
struct RecordingNotchIsland: View {
    @Bindable var model: RecordingControlBarModel
    @State private var isConfirmingCancel = false
    @State private var isExpanded = false

    var body: some View {
        Group {
            if let preRoll = model.preRoll, let settings = model.settings {
                preRollIsland(preRoll: preRoll, settings: settings)
            } else {
                liveIsland
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .padding(.top, 4)
        .frame(width: islandWidth, height: RecordingControlBar.notchContentHeight)
        .foregroundStyle(.white)
        .background(RecordingNotchShape().fill(.black))
        .clipShape(RecordingNotchShape())
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: model.notchVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isExpanded)
        .animation(.snappy(duration: 0.22), value: model.isPaused)
        .animation(.snappy(duration: 0.22), value: model.microphoneIsSilent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { hovering in
            isExpanded = hovering
        }
    }

    private var islandWidth: CGFloat {
        guard model.notchVisible else { return 0 }
        if model.preRoll != nil {
            return 340
        }
        return isExpanded || model.microphoneIsSilent ? 360 : 220
    }

    private var liveIsland: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isPaused ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
                .opacity(model.isPaused ? 0.45 : 1)
                .accessibilityLabel(model.isPaused ? "Paused" : "Recording")

            Text(model.elapsedText)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(minWidth: 36, alignment: .leading)
                .accessibilityLabel("Recording time")

            RecordingAudioMeter(level: model.audioLevel)

            if model.microphoneIsSilent {
                Text("Mic silent")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Microphone is silent")
            }

            Spacer(minLength: 4)

            RecordingBarCircleButton(
                symbol: model.isPaused ? "play.fill" : "pause.fill",
                help: model.isPaused ? "Resume" : "Pause",
                tint: .white
            ) {
                model.togglePause()
            }
            .accessibilityLabel(model.isPaused ? "Resume recording" : "Pause recording")

            RecordingBarFilledCircleButton(
                symbol: "stop.fill",
                help: "Stop and keep the recording (⌃⇧.)"
            ) {
                model.stop()
            }
            .accessibilityLabel("Stop and save")

            if isExpanded {
                RecordingBarCircleButton(
                    symbol: "arrow.counterclockwise",
                    help: "Start over — discard what's recorded and record again",
                    tint: .white
                ) {
                    model.restart()
                }
                .accessibilityLabel("Restart recording")

                RecordingBarCircleButton(symbol: "trash", help: "Discard this recording", tint: .white) {
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
        }
    }

    private func preRollIsland(
        preRoll: RecordingControlBar.PreRoll,
        settings: AppSettings
    ) -> some View {
        HStack(spacing: 8) {
            Text("\(max(preRoll.remaining, 1))")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(minWidth: 22, alignment: .center)
                .contentTransition(.numericText(countsDown: true))
                .accessibilityLabel("Starting in \(preRoll.remaining) seconds")

            RecordingBarCircleButton(
                symbol: settings.recordsMicrophone ? "mic.fill" : "mic.slash.fill",
                help: settings.recordsMicrophone ? "Microphone is on" : "Microphone is off",
                isOn: settings.recordsMicrophone,
                tint: .white
            ) {
                settings.recordsMicrophone.toggle()
            }
            .disabled(!RecordingOptions.microphoneIsAvailable)

            RecordingBarCircleButton(
                symbol: settings.recordsSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                help: settings.recordsSystemAudio ? "System sound is on" : "System sound is off",
                isOn: settings.recordsSystemAudio,
                tint: .white
            ) {
                settings.recordsSystemAudio.toggle()
            }

            RecordingBarCircleButton(
                symbol: settings.recordingShowsWebcam ? "video.fill" : "video.slash.fill",
                help: settings.recordingShowsWebcam ? "Camera is on" : "Camera is off",
                isOn: settings.recordingShowsWebcam,
                tint: .white
            ) {
                settings.recordingShowsWebcam.toggle()
            }

            Spacer(minLength: 4)

            RecordingBarFilledCircleButton(
                symbol: "play.fill",
                help: "Skip countdown and start now"
            ) {
                preRoll.startNow()
            }
            .accessibilityLabel("Start now")

            RecordingBarCircleButton(symbol: "xmark", help: "Cancel", tint: .white) {
                preRoll.cancel()
            }
            .accessibilityLabel("Cancel countdown")
        }
    }
}
