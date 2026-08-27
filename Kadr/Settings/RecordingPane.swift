import SettingsKit
import SwiftUI

/// Recording settings (docs/03 §1.8, §8.3).
struct RecordingPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Frame rate", selection: $settings.recordingFrameRate) {
                    ForEach(RecordingQuality.allCases, id: \.self) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                Picker("Format", selection: $settings.recordingCodec) {
                    ForEach(RecordingVideoCodec.allCases, id: \.self) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
            } footer: {
                Text("HEVC is about half the size at the same quality and every Mac that "
                    + "runs macOS 14 encodes it in hardware.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Toggle("Record system audio", isOn: $settings.recordsSystemAudio)
                Toggle("Record microphone", isOn: $settings.recordsMicrophone)
                Text("System audio needs no driver — macOS captures it directly. The "
                    + "microphone is recorded as a separate track so it can be dropped later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Overlays") {
                Toggle("Show the pointer", isOn: $settings.recordingShowsCursor)
                Toggle("Highlight clicks", isOn: $settings.recordingShowsClicks)
                Toggle("Show pressed keys", isOn: $settings.recordingShowsKeystrokes)
                Toggle(
                    "Only show keys pressed with \u{2318}, \u{2325} or \u{2303}",
                    isOn: $settings.recordingKeystrokesShortcutsOnly
                )
                .disabled(!settings.recordingShowsKeystrokes)
                Text("Showing every keystroke also shows whatever gets typed into a "
                    + "password field. Reading keys needs Accessibility permission, which "
                    + "Kadr asks for the first time a recording starts with this on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Show the webcam", isOn: $settings.recordingShowsWebcam)
            }

            Section {
                Toggle("Reduce interruptions while recording", isOn: $settings.recordingEnablesFocus)
            } footer: {
                Text("Overlays are drawn into the recording itself, not onto the screen, so "
                    + "nothing about them appears on other people's shared displays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
