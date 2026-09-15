import AppKit
import OverlayKit
import RecordingCore
import SettingsKit
import Shared
import SwiftUI

/// The picker's controls. One row inside the recording bar's glass, which
/// `RecordingControlBar` owns so Record can morph this into the countdown.
struct RecordSetupView: View {
    @Bindable var model: RecordSetupModel

    private static let timerOptions = [0, 1, 3, 5, 10]

    var body: some View {
        HStack(spacing: RecordingBarMetrics.controlSpacing) {
            sources
            RecordingBarDivider()
            inputs
            RecordingBarDivider()
            timerMenu
            recordButton
            closeButton
        }
        .onExitCommand { model.cancel() }
        .onAppear { model.refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAfterPermissionChange()
        }
        .popover(item: model.accessPromptItem, arrowEdge: .top) { kind in
            CaptureAccessPromptView(
                kind: kind,
                onAllow: { model.allowAccess() },
                onOpenSettings: { model.openAccessSettings() },
                onUseWithout: { model.useWithoutAccess() }
            )
        }
        .kadrLayoutDirection()
    }

    private var recordButton: some View {
        RecordingBarFilledCircleButton(
            symbol: "record.circle.fill",
            help: "Start recording"
        ) {
            model.record()
        }
        .disabled(model.armedTarget == nil)
        .accessibilityLabel("Start recording")
    }

    private var closeButton: some View {
        RecordingBarCircleButton(symbol: "xmark", help: "Close the recorder (Esc)") {
            model.cancel()
        }
        .accessibilityLabel("Close")
    }

    @ViewBuilder
    private var sources: some View {
        if model.displays.count > 1 {
            Menu {
                ForEach(model.displays) { display in
                    Button {
                        model.armScreen(display.displayID)
                    } label: {
                        if case let .screen(id) = model.armedTarget, id == display.displayID {
                            Label(display.name, systemImage: "checkmark")
                        } else {
                            Text(display.name)
                        }
                    }
                }
            } label: {
                RecordingBarIcon(
                    symbol: RecordTargetKind.screen.symbol,
                    isOn: model.isArmed(.screen)
                )
            }
            .recordingBarMenu(tooltip: "Select which screen to record")
            .accessibilityLabel("Display")
            .accessibilityValue(model.isArmed(.screen) ? "Selected" : "Off")
        } else {
            RecordingBarCircleButton(
                symbol: RecordTargetKind.screen.symbol,
                help: "Select the whole screen",
                isOn: model.isArmed(.screen)
            ) {
                model.armScreen(model.displays.first?.displayID ?? CGMainDisplayID())
            }
            .accessibilityLabel("Display")
            .accessibilityValue(model.isArmed(.screen) ? "Selected" : "Off")
        }

        RecordingBarCircleButton(
            symbol: RecordTargetKind.window.symbol,
            help: windowHelp,
            isOn: model.isArmed(.window)
        ) {
            model.requestWindowPick()
        }
        .accessibilityLabel("Window")
        .accessibilityValue(windowAccessibilityValue)

        RecordingBarCircleButton(
            symbol: RecordTargetKind.area.symbol,
            help: model.isArmed(.area) ? "Area selected — click to choose another" : "Drag to select a region",
            isOn: model.isArmed(.area)
        ) {
            model.requestAreaPick()
        }
        .accessibilityLabel("Area")
        .accessibilityValue(model.isArmed(.area) ? "Selected" : "Off")
    }

    private var windowHelp: String {
        if case let .window(_, title) = model.armedTarget {
            return "Window — \(title)"
        }
        return "Click the window to record"
    }

    private var windowAccessibilityValue: String {
        if case let .window(_, title) = model.armedTarget {
            return title
        }
        return "Off"
    }

    private var inputs: some View {
        HStack(spacing: RecordingBarMetrics.controlSpacing) {
            cameraToggle
            microphoneMenu
            RecordingBarCircleButton(
                symbol: model.settings.recordsSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill",
                help: model.settings.recordsSystemAudio ? "System audio on" : "System audio off",
                isOn: model.settings.recordsSystemAudio
            ) {
                model.settings.recordsSystemAudio.toggle()
            }
            .accessibilityLabel("System sound")
            .accessibilityValue(model.settings.recordsSystemAudio ? "On" : "Off")

            RecordingBarCircleButton(
                symbol: model.settings.recordingShowsClicks ? "hand.tap.fill" : "hand.tap",
                help: model.settings.recordingShowsClicks
                    ? "Click highlights on"
                    : "Click highlights off — a halo where you click",
                isOn: model.settings.recordingShowsClicks
            ) {
                model.settings.recordingShowsClicks.toggle()
            }
            .accessibilityLabel("Click highlights")
            .accessibilityValue(model.settings.recordingShowsClicks ? "On" : "Off")

            RecordingBarCircleButton(
                symbol: model.settings.recordingShowsKeystrokes ? "command.square.fill" : "command",
                help: model.settings.recordingShowsKeystrokes
                    ? "Keystroke overlay on — shortcuts appear on the recording"
                    : "Keystroke overlay off — turn on to show shortcuts on the video",
                isOn: model.settings.recordingShowsKeystrokes
            ) {
                model.settings.recordingShowsKeystrokes.toggle()
            }
            .accessibilityLabel("Keystroke overlay")
            .accessibilityValue(model.settings.recordingShowsKeystrokes ? "On" : "Off")

            RecordingBarCircleButton(
                symbol: "text.alignleft",
                help: model.settings.teleprompterEnabled
                    ? "Teleprompter on — click to edit the script"
                    : "Teleprompter off — click to write a script",
                isOn: model.settings.teleprompterEnabled
            ) {
                model.onTeleprompterComposer()
            }
            .accessibilityLabel("Teleprompter")
            .accessibilityValue(model.settings.teleprompterEnabled ? "On" : "Off")
        }
    }

    private var cameraToggle: some View {
        RecordingBarCircleButton(
            symbol: model.settings.recordingShowsWebcam ? "video.fill" : "video.slash.fill",
            help: cameraHelp,
            isOn: model.settings.recordingShowsWebcam
        ) {
            model.requestCameraToggle()
        }
        .contextMenu { cameraDeviceMenu }
        .disabled(cameraUnavailable)
        .accessibilityLabel("Camera")
        .accessibilityValue(model.settings.recordingShowsWebcam ? "On" : "Off")
    }

    private var cameraUnavailable: Bool {
        model.cameras.isEmpty && CaptureMediaAccess.status(for: .camera) == .allowed
    }

    private var cameraDeviceMenu: some View {
        ForEach(model.cameras) { device in
            Button {
                model.selectCamera(deviceID: device.uniqueID)
            } label: {
                if model.settings.recordingCameraDeviceID == device.uniqueID {
                    Label(device.localizedName, systemImage: "checkmark")
                } else {
                    Text(device.localizedName)
                }
            }
        }
    }

    private var cameraHelp: String {
        guard model.settings.recordingShowsWebcam else {
            return "Camera off — click to record your camera, right-click to pick one"
        }
        if let match = model.cameras.first(where: { $0.uniqueID == model.settings.recordingCameraDeviceID }) {
            return "Camera on — \(match.localizedName)"
        }
        return "Camera on — right-click to pick one"
    }

    @ViewBuilder
    private var microphoneMenu: some View {
        if RecordingOptions.microphoneIsAvailable {
            Menu {
                Button {
                    model.settings.recordsMicrophone = false
                } label: {
                    microphoneLabel("Off", selected: !model.settings.recordsMicrophone)
                }
                if !model.microphones.isEmpty {
                    Divider()
                    ForEach(model.microphones) { device in
                        Button {
                            model.settings.recordingMicrophoneDeviceID = device.uniqueID
                            model.requestMicrophoneEnabled(true)
                        } label: {
                            microphoneLabel(
                                device.localizedName,
                                selected: model.settings.recordsMicrophone
                                    && model.settings.recordingMicrophoneDeviceID == device.uniqueID
                            )
                        }
                    }
                }
            } label: {
                RecordingBarIcon(
                    symbol: model.settings.recordsMicrophone ? "mic.fill" : "mic.slash.fill",
                    isOn: model.settings.recordsMicrophone
                )
            }
            .recordingBarMenu(
                tooltip: model.settings.recordsMicrophone ? "Microphone on" : "Microphone off"
            )
            .accessibilityLabel("Microphone")
            .accessibilityValue(model.settings.recordsMicrophone ? "On" : "Off")
        }
    }

    @ViewBuilder
    private func microphoneLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var timerMenu: some View {
        Menu {
            ForEach(Self.timerOptions, id: \.self) { seconds in
                Button {
                    model.settings.recordingCountdownSeconds = seconds
                } label: {
                    if model.settings.recordingCountdownSeconds == seconds {
                        Label(timerTitle(seconds), systemImage: "checkmark")
                    } else {
                        Text(timerTitle(seconds))
                    }
                }
            }
        } label: {
            RecordingBarIcon(
                symbol: "timer",
                isOn: model.settings.recordingCountdownSeconds > 0
            )
        }
        .recordingBarMenu(
            tooltip: model.settings.recordingCountdownSeconds == 0
                ? "Timer off"
                : "Timer \(model.settings.recordingCountdownSeconds)s"
        )
        .accessibilityLabel("Countdown")
    }

    private func timerTitle(_ seconds: Int) -> String {
        seconds == 0 ? KadrText.string("None") : KadrPlural.seconds(seconds)
    }
}
