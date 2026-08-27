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

            Section {
                Toggle("Show the pointer", isOn: $settings.recordingShowsCursor)
                Toggle("Reduce interruptions while recording", isOn: $settings.recordingEnablesFocus)
            }
        }
        .formStyle(.grouped)
    }
}
