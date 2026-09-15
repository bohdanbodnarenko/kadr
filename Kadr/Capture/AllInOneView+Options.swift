import RecordingCore
import SettingsKit
import SwiftUI

extension AllInOneView {
    var saveTargetMenu: some View {
        Menu {
            Button {
                model.settings.askForSaveDestination = false
            } label: {
                saveTargetLabel("Save to default folder", selected: !model.settings.askForSaveDestination)
            }
            Button {
                model.settings.askForSaveDestination = true
            } label: {
                saveTargetLabel("Ask where to save", selected: model.settings.askForSaveDestination)
            }
        } label: {
            RecordingBarIcon(
                symbol: model.settings.askForSaveDestination ? "folder.badge.questionmark" : "folder",
                isOn: model.settings.askForSaveDestination
            )
        }
        .recordingBarMenu(tooltip: saveTargetHelp)
        .accessibilityLabel("Save target")
        .accessibilityValue(
            model.settings.askForSaveDestination ? "Ask where to save" : "Default folder"
        )
    }

    var recordingAudioMenu: some View {
        Menu {
            Button {
                model.settings.recordsSystemAudio.toggle()
            } label: {
                saveTargetLabel(
                    model.settings.recordsSystemAudio ? "System sound on" : "System sound off",
                    selected: model.settings.recordsSystemAudio
                )
            }
            if RecordingOptions.microphoneIsAvailable {
                Button {
                    model.settings.recordsMicrophone.toggle()
                } label: {
                    saveTargetLabel(
                        model.settings.recordsMicrophone ? "Microphone on" : "Microphone off",
                        selected: model.settings.recordsMicrophone
                    )
                }
            }
        } label: {
            RecordingBarIcon(
                symbol: recordingAudioSymbol,
                isOn: model.settings.recordsSystemAudio || model.settings.recordsMicrophone
            )
        }
        .recordingBarMenu(tooltip: "Audio for the next recording")
        .accessibilityLabel("Recording audio")
        .accessibilityValue(recordingAudioValue)
    }

    var optionsMenu: some View {
        Menu {
            Section("Timer") {
                ForEach(timerOptions, id: \.self) { seconds in
                    Button(timerLabel(seconds)) {
                        if seconds == model.settings.customTimerSeconds, seconds > 0 {
                            model.settings.selfTimer = .off
                        } else {
                            model.settings.customTimerSeconds = 0
                            model.settings.selfTimer = SelfTimer(rawValue: seconds) ?? .off
                        }
                    }
                }
            }
            Section("Save") {
                Button {
                    model.settings.askForSaveDestination = false
                } label: {
                    saveTargetLabel("Save to default folder", selected: !model.settings.askForSaveDestination)
                }
                Button {
                    model.settings.askForSaveDestination = true
                } label: {
                    saveTargetLabel("Ask where to save", selected: model.settings.askForSaveDestination)
                }
            }
            Section("Recording audio") {
                Button {
                    model.settings.recordsSystemAudio.toggle()
                } label: {
                    saveTargetLabel(
                        model.settings.recordsSystemAudio ? "System sound on" : "System sound off",
                        selected: model.settings.recordsSystemAudio
                    )
                }
                if RecordingOptions.microphoneIsAvailable {
                    Button {
                        model.settings.recordsMicrophone.toggle()
                    } label: {
                        saveTargetLabel(
                            model.settings.recordsMicrophone ? "Microphone on" : "Microphone off",
                            selected: model.settings.recordsMicrophone
                        )
                    }
                }
            }
        } label: {
            RecordingBarIcon(symbol: "slider.horizontal.3")
        }
        .recordingBarMenu(tooltip: "Timer, save target, and recording audio")
        .accessibilityLabel("Capture options")
    }

    @ViewBuilder
    func saveTargetLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    var saveTargetHelp: String {
        if model.settings.askForSaveDestination {
            return "Ask where to save — click to use the default folder"
        }
        return "Save to \(model.settings.saveFolder.lastPathComponent)"
    }

    var recordingAudioSymbol: String {
        if model.settings.recordsMicrophone {
            return "mic.fill"
        }
        if model.settings.recordsSystemAudio {
            return "speaker.wave.2.fill"
        }
        return "speaker.slash.fill"
    }

    var recordingAudioValue: String {
        var parts: [String] = []
        if model.settings.recordsSystemAudio {
            parts.append("System sound")
        }
        if model.settings.recordsMicrophone {
            parts.append("Microphone")
        }
        return parts.isEmpty ? "Off" : parts.joined(separator: ", ")
    }
}
