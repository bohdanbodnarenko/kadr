import RecordingCore
import SettingsKit
import SwiftUI

extension AllInOneView {
    /// Where the next screenshot goes (docs/03 §2). Writes the after-capture matrix, not
    /// the card's own Save setting, which this menu used to flip by mistake (T-CAP-12).
    var saveTargetMenu: some View {
        let current = model.settings.afterCapture.screenshotSaveTarget
        return Menu {
            ForEach(ScreenshotSaveTarget.allCases, id: \.self) { target in
                Button {
                    model.settings.afterCapture.screenshotSaveTarget = target
                } label: {
                    saveTargetLabel(target.title, selected: current == target)
                }
            }
        } label: {
            RecordingBarIcon(symbol: Self.saveTargetSymbol(current), isOn: current != .none)
        }
        .recordingBarMenu(tooltip: saveTargetHelp)
        .accessibilityLabel("Save target")
        .accessibilityValue(current.title)
    }

    static func saveTargetSymbol(_ target: ScreenshotSaveTarget) -> String {
        switch target {
        case .folder: "folder"
        case .ask: "folder.badge.questionmark"
        case .none: "rectangle.on.rectangle"
        }
    }

    var recordingAudioMenu: some View {
        Menu {
            Button {
                model.settings.recordsSystemAudio.toggle()
            } label: {
                saveTargetLabel(
                    model.settings.recordsSystemAudio ? "System audio on" : "System audio off",
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
                        selectTimer(seconds)
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
                        model.settings.recordsSystemAudio ? "System audio on" : "System audio off",
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
        switch model.settings.afterCapture.screenshotSaveTarget {
        case .folder: String(localized: "Screenshots save to \(model.settings.saveFolder.lastPathComponent)")
        case .ask: String(localized: "Kadr asks where to save each screenshot")
        case .none: String(localized: "Screenshots stay on their card until you save them")
        }
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
            parts.append("System audio")
        }
        if model.settings.recordsMicrophone {
            parts.append("Microphone")
        }
        return parts.isEmpty ? "Off" : parts.joined(separator: ", ")
    }
}
