import CaptureCore
import KeyboardShortcuts
import SettingsKit
import SwiftUI

/// Three screens, all skippable, under two minutes (docs/03 §8.2).
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    /// Bound separately: the settings object is what the picker writes to, and a
    /// computed passthrough on the model would be read-only.
    @Bindable var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 560, height: 460)
        // Reduced motion is honoured throughout (docs/03 §9).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.step)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .screenRecording: screenRecording
        case .defaults: defaults
        }
    }

    // MARK: - Screens

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(model.step.title, subtitle: "Screenshots that stay on your Mac.")

            Text("Kadr never uploads anything. There is no account, no cloud and no "
                + "analytics — sharing is dragging a capture into whatever app you like.")
                .foregroundStyle(.secondary)

            GroupBox("Your shortcuts") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(CaptureCommand.allCases, id: \.self) { command in
                        HStack {
                            Text(command.title)
                            Spacer()
                            Text(shortcutText(for: command))
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private var screenRecording: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(model.step.title, subtitle: "macOS asks before any app can record the screen.")

            switch model.permissionState {
            case .granted:
                Label("Kadr can capture your screen.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if model.needsRelaunch {
                    // macOS hands a running process a grant it cannot use, so the app has
                    // to restart. Doing it for the user is the difference between working
                    // and appearing broken (docs/04 §4.1).
                    Text("macOS only applies a new permission to a freshly launched app, "
                        + "so Kadr needs to restart once.")
                        .foregroundStyle(.secondary)
                    Button("Restart Kadr", action: model.relaunch)
                        .buttonStyle(.borderedProminent)
                }
            default:
                Text("Kadr needs Screen Recording permission to take screenshots. "
                    + "Nothing leaves your Mac.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Ask macOS", action: model.requestScreenRecording)
                        .buttonStyle(.borderedProminent)
                    Button("Open System Settings", action: model.openSystemSettings)
                }

                if model.permissionState.needsUserAction {
                    Label(
                        "Turn Kadr on under Privacy & Security → Screen & System Audio Recording.",
                        systemImage: "arrow.right.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("macOS 15 asks you to confirm this about once a month.", systemImage: "calendar")
                    Text("That is macOS, not Kadr — every screen-capture app is asked. "
                        + "Kadr will tell you when it happens instead of silently failing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            // The no-permission path, so the app is useful before any of this is settled
            // (docs/04 §4.1).
            Text("You can skip this. Kadr can still capture a window or screen you pick "
                + "through the macOS sharing picker, which needs no permission at all.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear { model.startWatchingForGrant() }
        .onDisappear { model.stopWatchingForGrant() }
    }

    private var defaults: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(model.step.title, subtitle: "You can change all of this later in Settings.")

            Picker("After capturing", selection: $settings.defaultAction) {
                ForEach(DefaultCaptureAction.allCases, id: \.self) { action in
                    Text(action.title).tag(action)
                }
            }
            .pickerStyle(.radioGroup)

            LabeledContent("Save to") {
                HStack {
                    Text(settings.saveFolder.path)
                        .truncationMode(.head)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…", action: model.chooseSaveFolder)
                }
            }

            Toggle("Launch Kadr at login", isOn: Binding(
                get: { model.loginItemState.isOn },
                set: { model.setLaunchAtLogin($0) }
            ))
            if let explanation = model.loginItemState.explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Chrome

    private func header(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            // Every screen is skippable (docs/03 §8.2).
            Button("Skip", action: model.skip)
                .buttonStyle(.borderless)
            Spacer()
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Circle()
                    .fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
            Spacer()
            Button(model.isLastStep ? "Done" : "Continue", action: model.advance)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func shortcutText(for command: CaptureCommand) -> String {
        KeyboardShortcuts.getShortcut(for: command.shortcutName)?.description ?? "Not set"
    }
}
