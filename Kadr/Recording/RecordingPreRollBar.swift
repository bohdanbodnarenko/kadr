import RecordingCore
import SettingsKit
import SwiftUI

/// The recording bar's contents while the countdown runs.
///
/// Remaining seconds take the clock's place, in the clock's type. Skip and Cancel are the
/// same controls the live bar uses for Stop and Discard, so this is not a different app
/// for three seconds.
struct RecordingPreRollBar: View {
    let preRoll: RecordingControlBar.PreRoll
    let settings: AppSettings
    /// Off in the notch island, whose ear already shows the countdown.
    var showsCountdown = true

    var body: some View {
        HStack(spacing: RecordingBarMetrics.controlSpacing) {
            if showsCountdown {
                Text("\(max(preRoll.remaining, 1))")
                    .font(.system(size: 16, weight: .medium, design: .monospaced).monospacedDigit())
                    .foregroundStyle(RecordingBarMetrics.activeTint)
                    .frame(minWidth: 28, alignment: .center)
                    .padding(.leading, 8)
                    .padding(.trailing, 2)
                    .frame(height: RecordingBarMetrics.controlSize)
                    .contentTransition(.numericText(countsDown: true))
                    .kadrAnimation(.snappy, value: preRoll.remaining)
                    .accessibilityLabel("Starting in \(preRoll.remaining) seconds")

                RecordingBarDivider()
            }

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
        .onExitCommand { preRoll.cancel() }
    }
}
