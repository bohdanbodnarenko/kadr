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

    private static let welcomeCommands: [CaptureCommand] = [
        .captureArea, .captureWindow, .captureFullscreen, .recordDisplay
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ScrollView(showsIndicators: false) {
                        content
                            .frame(maxWidth: 560)
                            .padding(28)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                            .id("stepContent")
                    }
                }
                .onChange(of: model.step) { _, _ in
                    proxy.scrollTo("stepContent", anchor: .top)
                }
            }
            Divider()
            footer
                .padding(16)
        }
        .frame(minWidth: 520, minHeight: 560)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.step)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.step == .permissions {
                model.refreshPermissions()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .permissions: permissions
        case .defaults: defaults
        }
    }

    // MARK: - Screens

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                header(model.step.title, subtitle: "Screenshots and recordings that stay on your Mac.")
            }

            Text("Kadr never uploads anything. There is no account, no cloud and no "
                + "analytics — sharing is dragging a capture into whatever app you like.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Your shortcuts") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.welcomeCommands, id: \.self) { command in
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

            Text("Every shortcut can be changed later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(
                model.step.title,
                subtitle: "Allow screen capture to get started. Choose the other features you’ll use."
            )

            if model.needsRelaunch {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "macOS only applies a new permission to a freshly launched app, so Kadr needs to restart once."
                    )
                    .foregroundStyle(.secondary)
                    Button("Restart Kadr", action: model.relaunch)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(spacing: 8) {
                ForEach(AppPermission.allCases) { permission in
                    AppPermissionRow(
                        permission: permission,
                        status: model.appPermissions.status(permission),
                        attempted: model.appPermissions.attempted.contains(permission),
                        isRequesting: model.appPermissions.requesting == permission,
                        requestsDisabled: model.appPermissions.requesting != nil,
                        errorMessage: model.appPermissions.settingsErrorPermission == permission
                            ? model.appPermissions.settingsError
                            : nil,
                        request: { model.request(permission) },
                        openSettings: { model.openSystemSettings(permission) }
                    )
                }
            }

            HStack {
                Text("Access updates when you return here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { model.refreshPermissions() }
                    .disabled(model.appPermissions.requesting != nil)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("macOS 15 asks you to confirm screen recording about once a month.", systemImage: "calendar")
                    Text("That is macOS, not Kadr — every screen-capture app is asked. "
                        + "Kadr will tell you when it happens instead of silently failing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            Text("Microphone and camera stay off until you choose them for a recording. "
                + "You can skip this: Kadr can still capture a window you pick through the "
                + "macOS sharing picker, which needs no permission at all.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            Button(action: model.openPracticeImage) {
                HStack(spacing: 14) {
                    practiceThumbnail
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Try a practice image")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Add an arrow, change the background, then export. No screen access needed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens a separate copy in the image editor.")

            if let practiceError = model.practiceError {
                Label(practiceError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if model.appPermissions.status(.screen) != .allowed {
                Text("Screen access is off. Practice works without it, and the menu bar icon is always there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var practiceThumbnail: some View {
        Group {
            if let image = OnboardingPracticeImage.render(width: 152, height: 96) {
                Image(nsImage: NSImage(cgImage: image, size: NSSize(width: 76, height: 48)))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 48)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 76, height: 48)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Chrome

    private func header(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.canGoBack {
                Button {
                    model.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .help("Back")
                .accessibilityLabel("Previous step")
            }
            Text("\(model.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Skip Setup", action: model.skip)
                .keyboardShortcut(.cancelAction)
            Button(model.isLastStep ? "Done" : nextTitle, action: model.advance)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.appPermissions.requesting != nil)
        }
    }

    private var nextTitle: String {
        switch model.step {
        case .welcome: "Get Started"
        case .permissions: "Continue"
        case .defaults: "Done"
        }
    }

    private func shortcutText(for command: CaptureCommand) -> String {
        KeyboardShortcuts.getShortcut(for: command.shortcutName)?.description ?? "Not set"
    }
}
