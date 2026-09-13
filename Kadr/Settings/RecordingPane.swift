import AppKit
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
                Toggle("Record in mono", isOn: $settings.recordsMono)
                Text("System audio needs no driver — macOS captures it directly. The "
                    + "microphone is recorded as a separate track so it can be dropped later. "
                    + "Mono is smaller and what most screen recordings want. "
                    + "Pick which microphone from the recording bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Before recording") {
                Picker("Countdown", selection: $settings.recordingCountdownSeconds) {
                    Text("Off").tag(0)
                    Text("1 second").tag(1)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Text("Time to get into position before the recording starts. "
                    + "Press the recording shortcut again to call it off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("While recording") {
                Toggle("Show the floating controls", isOn: $settings.recordingShowsControlBar)
                Text("A compact bar for picking what to record, then Stop, Pause, Restart "
                    + "and Discard while it runs. It never appears in the recording, and "
                    + "you can drag it anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Overlays") {
                Toggle("Show the pointer", isOn: $settings.recordingShowsCursor)
                Toggle("Highlight clicks", isOn: $settings.recordingShowsClicks)
                if settings.recordingShowsClicks {
                    Picker("Click style", selection: clickStyleBinding) {
                        Text("Outline").tag(false)
                        Text("Filled").tag(true)
                    }
                    Slider(value: $settings.recordingClickScale, in: 0.5 ... 2.5) {
                        Text("Click size")
                    }
                    ColorPicker(
                        "Click colour",
                        selection: clickColorBinding,
                        supportsOpacity: false
                    )
                }
                Toggle("Show pressed keys", isOn: $settings.recordingShowsKeystrokes)
                Toggle(
                    "Only show keys pressed with \u{2318}, \u{2325} or \u{2303}",
                    isOn: $settings.recordingKeystrokesShortcutsOnly
                )
                .disabled(!settings.recordingShowsKeystrokes)
                if settings.recordingShowsKeystrokes {
                    Picker("Keystroke position", selection: $settings.recordingKeystrokePosition) {
                        ForEach(RecordingKeystrokePosition.allCases, id: \.self) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    Picker("Keystroke theme", selection: $settings.recordingKeystrokeAppearance) {
                        ForEach(OverlayChromeAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    Slider(value: $settings.recordingKeystrokeScale, in: 0.6 ... 1.8) {
                        Text("Keystroke size")
                    }
                }
                Text("Showing every keystroke also shows whatever gets typed into a "
                    + "password field. Reading keys needs Accessibility permission, which "
                    + "Kadr asks for the first time a recording starts with this on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Show the webcam", isOn: $settings.recordingShowsWebcam)
                if settings.recordingShowsWebcam {
                    Toggle("Circular webcam", isOn: $settings.recordingWebcamCircular)
                    Toggle("Fill the frame", isOn: $settings.recordingWebcamFillsFrame)
                    Slider(value: $settings.recordingWebcamSize, in: 0.08 ... 0.6) {
                        Text("Webcam size")
                    }
                    .disabled(settings.recordingWebcamFillsFrame)
                }
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

    private var clickStyleBinding: Binding<Bool> {
        Binding(
            get: { settings.recordingClickFilled },
            set: { settings.recordingClickFilled = $0 }
        )
    }

    private var clickColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: settings.recordingClickRed,
                    green: settings.recordingClickGreen,
                    blue: settings.recordingClickBlue
                )
            },
            set: { color in
                let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
                settings.recordingClickRed = resolved.redComponent
                settings.recordingClickGreen = resolved.greenComponent
                settings.recordingClickBlue = resolved.blueComponent
            }
        )
    }
}
