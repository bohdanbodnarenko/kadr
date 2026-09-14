import RecordingCore
import SettingsKit
import SwiftUI

/// The same capsule as the picker and the live bar, while the countdown runs.
///
/// Remaining seconds take the clock's place. Skip and Cancel are the same filled and
/// quiet circles the live bar uses for Stop and Discard, so this is not a different app
/// for three seconds.
struct RecordingPreRollBar: View {
    let preRoll: RecordingControlBar.PreRoll
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Text("\(max(preRoll.remaining, 1))")
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 28, alignment: .center)
                .contentTransition(.numericText(countsDown: true))
                .kadrAnimation(.snappy, value: preRoll.remaining)
                .accessibilityLabel("Starting in \(preRoll.remaining) seconds")

            RecordingBarDivider()

            if RecordingOptions.microphoneIsAvailable {
                RecordingBarCircleButton(
                    symbol: settings.recordsMicrophone ? "mic.fill" : "mic.slash.fill",
                    help: settings.recordsMicrophone ? "Microphone is on" : "Microphone is off",
                    isOn: settings.recordsMicrophone
                ) {
                    settings.recordsMicrophone.toggle()
                }
                .accessibilityLabel("Microphone")
                .accessibilityValue(settings.recordsMicrophone ? "On" : "Off")
            }
            RecordingBarCircleButton(
                symbol: settings.recordsSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                help: settings.recordsSystemAudio ? "System sound is on" : "System sound is off",
                isOn: settings.recordsSystemAudio
            ) {
                settings.recordsSystemAudio.toggle()
            }
            .accessibilityLabel("System sound")
            .accessibilityValue(settings.recordsSystemAudio ? "On" : "Off")
            RecordingBarCircleButton(
                symbol: settings.recordingShowsWebcam ? "video.fill" : "video.slash.fill",
                help: settings.recordingShowsWebcam ? "Camera is on" : "Camera is off",
                isOn: settings.recordingShowsWebcam
            ) {
                settings.recordingShowsWebcam.toggle()
            }
            .accessibilityLabel("Camera")
            .accessibilityValue(settings.recordingShowsWebcam ? "On" : "Off")

            RecordingBarDivider()

            RecordingBarFilledCircleButton(
                symbol: "play.fill",
                help: "Skip countdown and start now"
            ) {
                preRoll.startNow()
            }
            .accessibilityLabel("Start now")

            RecordingBarCircleButton(symbol: "xmark", help: "Cancel") {
                preRoll.cancel()
            }
            .accessibilityLabel("Cancel countdown")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RecordingBarBackground())
        .padding(10)
        .onExitCommand { preRoll.cancel() }
    }
}
