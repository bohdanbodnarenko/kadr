import AppKit
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

    private let logger = KadrLog.logger(.settings)

    var body: some View {
        Form {
            Section {
                Toggle("Launch Kadr at login", isOn: loginAtLoginBinding)
                if let explanation = loginItem.state.explanation {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ControlInlineStatus(status: loginItemStatus) {
                    loginItemStatus = nil
                }
            }

            Section("After capturing") {
                AfterCaptureMatrixEditor(settings: settings)
            }

            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(settings.saveFolder.path)
                            .truncationMode(.head)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseSaveFolder)
                    }
                }
                Toggle("Ask where to save from the overlay", isOn: $settings.askForSaveDestination)
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
                Toggle("Convert to sRGB when saving", isOn: $settings.convertExportsToSRGB)
                Text("Off keeps a wide-gamut capture in Display P3. On converts so "
                    + "browsers and Windows apps show the same colours as this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Annotate") {
                Toggle("Lock objects when the editor opens", isOn: $settings.lockCanvasByDefault)
                Toggle("Object shadows on inserted images", isOn: $settings.objectShadowsEnabled)
                Toggle("Keep the original file when saving annotations", isOn: $settings.keepOriginalWhenAnnotating)
                Text("Keeps existing annotations from moving while you draw. You can still "
                    + "toggle lock in the editor toolbar or with ⇧⌘L.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveFolderPath = url.path
    }
}
