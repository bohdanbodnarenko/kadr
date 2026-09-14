import AppKit
import OverlayKit
import RecordingCore
import SettingsKit
import Shared
import SwiftUI

/// The compact picker strip. One row, same chrome as the live recording bar.
struct RecordSetupView: View {
    @Bindable var model: RecordSetupModel

    private static let timerOptions = [0, 1, 3, 5, 10]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullStrip
            twoRowStrip
            compactStrip
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RecordingBarBackground())
        .padding(10)
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

    private var fullStrip: some View {
        HStack(spacing: 6) {
            sources
            RecordingBarDivider()
            inputs
            RecordingBarDivider()
            timerMenu
            closeButton
        }
    }

    private var twoRowStrip: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                sources
                Spacer(minLength: 0)
                closeButton
            }
            HStack(spacing: 6) {
                inputs
                RecordingBarDivider()
                timerMenu
                Spacer(minLength: 0)
            }
        }
    }

    private var compactStrip: some View {
        HStack(spacing: 6) {
            sources
            overflowInputsMenu
            RecordingBarDivider()
            timerMenu
            closeButton
        }
    }

    private var closeButton: some View {
        RecordingBarCircleButton(symbol: "xmark", help: "Close the recorder (Esc)") {
            model.cancel()
        }
        .accessibilityLabel("Close")
    }

    private var overflowInputsMenu: some View {
        Menu {
            Button {
                model.requestCameraToggle()
            } label: {
                Text(model.settings.recordingShowsWebcam ? "Camera on" : "Camera off")
            }
            if RecordingOptions.microphoneIsAvailable {
                Button {
                    model.requestMicrophoneEnabled(!model.settings.recordsMicrophone)
                } label: {
                    Text(model.settings.recordsMicrophone ? "Microphone on" : "Microphone off")
                }
            }
            Button {
                model.settings.recordsSystemAudio.toggle()
            } label: {
                Text(model.settings.recordsSystemAudio ? "System sound on" : "System sound off")
            }
            Button {
                model.settings.recordingShowsClicks.toggle()
            } label: {
                Text(model.settings.recordingShowsClicks ? "Click highlights on" : "Click highlights off")
            }
            Button {
                model.settings.recordingShowsKeystrokes.toggle()
            } label: {
                Text(model.settings.recordingShowsKeystrokes ? "Keystrokes on" : "Keystrokes off")
            }
            Button {
                model.onTeleprompterComposer()
            } label: {
                Text(model.settings.teleprompterEnabled ? "Teleprompter on" : "Teleprompter off")
            }
        } label: {
            RecordingBarIcon(symbol: "slider.horizontal.3")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Recording options")
        .accessibilityLabel("Recording options")
    }

    @ViewBuilder
    private var sources: some View {
        if model.displays.count > 1 {
            Menu {
                ForEach(model.displays) { display in
                    Button(display.name) { model.beginDisplay(display.displayID) }
                }
            } label: {
                RecordingBarIcon(symbol: RecordTargetKind.screen.symbol)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Pick a screen to record")
            .accessibilityLabel("Display — choose which screen to record")
        } else {
            RecordingBarCircleButton(
                symbol: RecordTargetKind.screen.symbol,
                help: "Record the whole screen"
            ) {
                model.begin(.screen)
            }
            .accessibilityLabel("Display — record the whole screen")
        }

        RecordingBarCircleButton(
            symbol: RecordTargetKind.window.symbol,
            help: "Pick an app window"
        ) {
            model.begin(.window)
        }
        .accessibilityLabel("Window — click the window to record")

        RecordingBarCircleButton(
            symbol: RecordTargetKind.area.symbol,
            help: "Drag to select a region"
        ) {
            model.begin(.area)
        }
        .accessibilityLabel("Area — drag to select the region to record")
    }

    private var inputs: some View {
        HStack(spacing: 6) {
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
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(model.settings.recordsMicrophone ? "Microphone on" : "Microphone off")
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
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(
            model.settings.recordingCountdownSeconds == 0
                ? "Timer off"
                : "Timer \(model.settings.recordingCountdownSeconds)s"
        )
        .accessibilityLabel("Countdown")
    }

    private func timerTitle(_ seconds: Int) -> String {
        seconds == 0 ? KadrText.string("None") : KadrPlural.seconds(seconds)
    }
}
