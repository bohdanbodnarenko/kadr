import AppKit
import MediaExport
import os
import SettingsKit
import Shared
import SwiftUI

/// General settings (docs/03 §8.3): login item, default action, save folder,
/// filename template, format, Retina downscale.
struct GeneralPane: View {
    @Bindable var settings: AppSettings
    let loginItem: LoginItemController

    private let logger = KadrLog.logger(.settings)

    var body: some View {
        Form {
            Section {
                Toggle("Launch Kadr at login", isOn: launchAtLoginBinding)
                if let explanation = loginItem.state.explanation {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("After capturing", selection: $settings.defaultAction) {
                    ForEach(DefaultCaptureAction.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }

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
            }
        }
        .formStyle(.grouped)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItem.state.isOn },
            set: { isOn in
                do {
                    try loginItem.setEnabled(isOn)
                } catch {
                    logger.error("Could not \(isOn ? "enable" : "disable") the login item: \(error)")
                }
            }
        )
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
