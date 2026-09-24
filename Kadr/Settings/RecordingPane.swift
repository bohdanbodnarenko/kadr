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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("HEVC keeps files smaller; HDR requires it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SettingsLearnMore(topic: .recordingFormat)
                }
            }

            Section {
                Toggle("Record system audio", isOn: $settings.recordsSystemAudio)
                Toggle("Record microphone", isOn: $settings.recordsMicrophone)
                    .disabled(!RecordingOptions.microphoneIsAvailable)
                if !RecordingOptions.microphoneIsAvailable {
                    Text("Recording the microphone needs macOS 15 or later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle("Record in mono", isOn: $settings.recordsMono)
            } header: {
                Text("Audio")
            } footer: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("The microphone is saved as its own track so you can drop it later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SettingsLearnMore(topic: .recordingAudio)
                }
            }

            Section {
                Picker("Countdown", selection: $settings.recordingCountdownSeconds) {
                    Text("Off").tag(0)
                    Text("1 second").tag(1)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            } header: {
                Text("Before recording")
            } footer: {
                Text("Press the recording shortcut again to cancel the countdown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show the floating controls", isOn: $settings.recordingShowsControlBar)
                Picker("Layout", selection: chromeBinding) {
                    Text(RecordingControlChrome.island.title).tag(RecordingControlChrome.island)
                    Text(RecordingControlChrome.notch.title).tag(RecordingControlChrome.notch)
                        .disabled(!RecordingNotchScreen.isAvailable)
                }
                .disabled(!settings.recordingShowsControlBar)
                if !RecordingNotchScreen.isAvailable {
                    Text("This Mac has no camera notch, so only the floating island is available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("While recording")
            } footer: {
                Text("The notch layout needs a camera cutout; the island can go anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show the pointer", isOn: $settings.recordingShowsCursor)
                Toggle("Highlight clicks", isOn: $settings.recordingShowsClicks)
                if settings.recordingShowsClicks {
                    Picker("Click style", selection: clickStyleBinding) {
                        Text("Outline").tag(false)
                        Text("Filled").tag(true)
                    }
                    SettingsValueRow(
                        title: "Click size",
                        value: $settings.recordingClickScale,
                        range: 0.5 ... 2.5,
                        step: 0.05
                    )
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
                    SettingsValueRow(
                        title: "Keystroke size",
                        value: $settings.recordingKeystrokeScale,
                        range: 0.6 ... 1.8,
                        step: 0.05
                    )
                }
                Toggle("Show the webcam", isOn: $settings.recordingShowsWebcam)
                if settings.recordingShowsWebcam {
                    Toggle("Circular webcam", isOn: $settings.recordingWebcamCircular)
                    Toggle("Fill the frame", isOn: $settings.recordingWebcamFillsFrame)
                    Picker("Webcam position", selection: $settings.recordingWebcamCorner) {
                        ForEach(RecordingWebcamCorner.allCases, id: \.self) { corner in
                            Text(corner.title).tag(corner)
                        }
                    }
                    .disabled(settings.recordingWebcamFillsFrame)
                    SettingsValueRow(
                        title: "Webcam size",
                        value: $settings.recordingWebcamSize,
                        range: 0.08 ... 0.6,
                        step: 0.01
                    )
                    .disabled(settings.recordingWebcamFillsFrame)
                }
            } header: {
                Text("Overlays")
            } footer: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(
                        "Keystroke overlays can reveal passwords. Reading keys needs Accessibility "
                            + "permission the first time you record with this on."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    SettingsLearnMore(topic: .overlays)
                }
            }

            TeleprompterSection(settings: settings)

            Section {
                DisclosureGroup("Studio capture") {
                    Toggle(
                        "Keep recordings editable in the studio",
                        isOn: $settings.recordingCapturesStudioSession
                    )
                    Toggle(
                        "Record without the pointer and draw it back",
                        isOn: $settings.recordingReconstructsCursor
                    )
                    .disabled(!settings.recordingCapturesStudioSession)
                }
            } footer: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(
                        "Editable data is a few kilobytes and enables smooth zooms and reconstructed "
                            + "clicks. Without it, those effects are gone once recording ends."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    SettingsLearnMore(topic: .studioCapture)
                }
            }

            Section {
                Toggle(
                    "Reduce interruptions while recording", isOn: $settings.recordingEnablesFocus
                )
                Toggle(
                    "Hide desktop icons while recording", isOn: $settings.hideDesktopDuringRecording
                )
            } footer: {
                Text("Both apply only while a recording runs, and are undone when it stops.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsFormChrome()
    }

    private var chromeBinding: Binding<RecordingControlChrome> {
        Binding(
            get: {
                RecordingNotchScreen.isAvailable ? settings.recordingControlChrome : .island
            },
            set: { settings.recordingControlChrome = $0 }
        )
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
                guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
                settings.recordingClickRed = resolved.redComponent
                settings.recordingClickGreen = resolved.greenComponent
                settings.recordingClickBlue = resolved.blueComponent
            }
        )
    }
}
