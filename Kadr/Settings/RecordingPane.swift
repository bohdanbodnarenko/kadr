import RecordingCore
import SettingsKit
import Shared
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
                if DynamicRange.isAvailable {
                    Picker("Dynamic range", selection: $settings.recordingDynamicRange) {
                        ForEach(DynamicRange.available, id: \.self) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .disabled(settings.recordingCodec != .hevc)
                }
            } footer: {
                Text("HEVC is about half the size at the same quality and every Mac that "
                    + "runs macOS 14 encodes it in hardware. HDR needs it: H.264 as Kadr "
                    + "configures it cannot carry ten bits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Toggle("Record system audio", isOn: $settings.recordsSystemAudio)
                Toggle("Record microphone", isOn: $settings.recordsMicrophone)
                    .disabled(!RecordingOptions.microphoneIsAvailable)
                if !RecordingOptions.microphoneIsAvailable {
                    Text("Recording the microphone needs macOS 15 or later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("System audio needs no driver — macOS captures it directly. The "
                    + "microphone is recorded as a separate track so it can be dropped later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("While recording") {
                Toggle("Show the floating controls", isOn: $settings.recordingShowsControlBar)
                Text("A small bar with Stop, Pause and Discard. It never appears in the "
                    + "recording, and you can drag it anywhere.")
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

            TeleprompterSection(settings: settings)

            Section("Studio") {
                Toggle("Keep recordings editable in the studio", isOn: $settings.recordingCapturesStudioSession)
                Text("Saves the pointer's path, clicks and shortcuts beside the recording so "
                    + "it can be given smooth zooms and reconstructed clicks later. It is a "
                    + "few kilobytes, and a recording made without it can never be given "
                    + "them — the information is gone once the recording ends.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Record without the pointer and draw it back", isOn: $settings.recordingReconstructsCursor)
                    .disabled(!settings.recordingCapturesStudioSession)
                Text("Makes zooms follow the pointer smoothly instead of dragging a "
                    + "stuck-on cursor with them. The saved file has no pointer in it at "
                    + "all until the studio puts one back, so leave this off for recordings "
                    + "you send straight on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Reduce interruptions while recording", isOn: $settings.recordingEnablesFocus)
                Toggle("Hide desktop icons while recording", isOn: $settings.hideDesktopDuringRecording)
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
