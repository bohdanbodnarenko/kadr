import AppKit
import ControlKit
import MediaExport
import os
import SettingsKit
import Shared
import SwiftUI

/// General settings (docs/03 §8.3): login item, default action, save folder,
/// optional ask-where-to-save, filename template, format, Retina downscale, optional sRGB conversion.
struct GeneralPane: View {
    @Bindable var settings: AppSettings
    let loginItem: LoginItemController

    @State private var loginItemStatus: FeedbackStatus?
    @State private var tipsStatus: FeedbackStatus?

    private let logger = KadrLog.logger(.settings)

    var body: some View {
        Form {
            Section {
                Toggle("Launch Kadr at login", isOn: loginAtLoginBinding)
                Toggle("Show menu bar icon", isOn: menuBarIconBinding)
                Text(
                    "Turn this off to hide Kadr from the menu bar. Reopen the app from Finder "
                        + "or the Dock to get back to Settings."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let explanation = loginItem.state.explanation {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ControlInlineStatus(status: loginItemStatus) {
                    loginItemStatus = nil
                }
            }

            Section {
                LabeledContent("First-run tips") {
                    Button("Show Tips Again") {
                        settings.hasSeenMenuBarHint = false
                        settings.hasSeenIslandTour = false
                        settings.hasSeenQuickAccessTip = false
                        tipsStatus = .done("They'll appear next launch, and on the next island and capture.")
                    }
                    .disabled(!settings.hasSeenMenuBarHint && !settings.hasSeenIslandTour
                        && !settings.hasSeenQuickAccessTip)
                }
                ControlInlineStatus(status: tipsStatus) {
                    tipsStatus = nil
                }
            }

            Section("After capturing") {
                AfterCaptureMatrixEditor(settings: settings)
            }

            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(settings.saveFolder.path)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .help(settings.saveFolder.path)
                        Spacer()
                        Button("Choose…", action: chooseSaveFolder)
                        Button("Use Default", action: restoreDefaultSaveFolder)
                    }
                }
                Toggle("Ask where to save from a card", isOn: $settings.askForSaveDestination)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Save on a card shows a folder picker instead of writing to this folder. "
                        + "After-capture “Ask where to save” does the same the moment a capture lands.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsLearnMore(topic: .saveTarget)
                }
            }

            Section {
                TextField("Filename", text: $settings.filenameTemplate)
                Text("Placeholders: {app}, {date}, {time}")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // Only formats ImageIO can write: macOS reads WebP but cannot encode it,
                // and offering it would produce a failed export rather than a file.
                Picker("Format", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.writable, id: \.self) { format in
                        Text(format.title).tag(format)
                    }
                }

                Toggle("Save Retina captures at 1×", isOn: $settings.downscaleRetinaCaptures)
                // The caption sits under the toggle it explains; it used to follow the sound
                // toggle and read as being about that (docs/17 T-SH-8).
                Toggle("Convert to sRGB when saving", isOn: $settings.convertExportsToSRGB)
                Text("Off keeps a wide-gamut capture in Display P3. On converts so "
                    + "browsers and Windows apps show the same colors as this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Play a sound when capturing", isOn: $settings.playsCaptureSound)
                if settings.imageFormat != .png {
                    KadrSlider(title: "Quality", value: $settings.lossyQuality, range: 0.1 ... 1)
                }
            }

            Section("Annotate") {
                Toggle("Lock objects when the editor opens", isOn: $settings.lockCanvasByDefault)
                // Directly under the toggle it explains (docs/18 X-5).
                Text("Keeps existing annotations from moving while you draw. You can still "
                    + "toggle lock in the editor toolbar or with ⇧⌘L.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Object shadows on inserted images", isOn: $settings.objectShadowsEnabled)
                Toggle("Keep the original file when saving annotations", isOn: $settings.keepOriginalWhenAnnotating)
            }
        }
        .settingsFormChrome()
    }

    private var loginAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItem.state.isOn },
            set: { requested in
                setLaunchAtLogin(requested)
            }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemStatus = nil
        do {
            try loginItem.setEnabled(enabled)
            if loginItem.state.isOn == enabled {
                let message = enabled
                    ? "Kadr will open at login."
                    : "Kadr will no longer open at login."
                loginItemStatus = .done(message)
                FeedbackAnnouncement.post(message)
            } else if let explanation = loginItem.state.explanation {
                loginItemStatus = FeedbackStatus(
                    kind: .warning,
                    message: explanation,
                    recoveryTitle: "Open Login Items",
                    recovery: openLoginItemsSettings
                )
                FeedbackAnnouncement.post(explanation)
            }
        } catch {
            let message = enabled
                ? "Could not register Kadr to open at login."
                : "Could not remove Kadr from login items."
            loginItemStatus = .failure(
                message,
                retryTitle: "Try Again",
                retry: { setLaunchAtLogin(enabled) }
            )
            FeedbackAnnouncement.post(message)
            logger.error("Could not \(enabled ? "enable" : "disable") the login item: \(error)")
        }
    }

    private func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            ?? URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane")
        NSWorkspace.shared.open(url)
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveFolder
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveFolderPath = url.path
    }

    private func restoreDefaultSaveFolder() {
        settings.saveFolderPath = SettingKeys.saveFolderPath.defaultValue
    }

    private var menuBarIconBinding: Binding<Bool> {
        Binding(
            get: { settings.showsMenuBarIcon },
            set: { visible in
                settings.showsMenuBarIcon = visible
                StatusItemController.postMenuBarVisibility(visible)
            }
        )
    }
}
