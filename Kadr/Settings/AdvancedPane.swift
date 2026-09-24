import AppKit
import OverlayKit
import SettingsKit
import SwiftUI

/// Advanced settings (docs/03 §8.3): the automation surfaces and the reset button.
struct AdvancedPane: View {
    @Bindable var settings: AppSettings

    private let installer = CLIInstaller()
    @State private var cliMessage: String?
    @State private var isInstalled = false
    @State private var showsResetConfirmation = false
    @State private var showsRemoveDataConfirmation = false

    var body: some View {
        Form {
            Section("Command Line Tool") {
                LabeledContent("kadr") {
                    HStack {
                        Button(isInstalled ? "Reinstall" : "Install") {
                            apply(installer.install())
                        }
                        .disabled(installer.bundledToolURL == nil)

                        Button("Remove") {
                            cliMessage = installer.uninstall().message
                            refresh()
                        }
                        .disabled(installer.installedURL == nil)
                    }
                }
                Text(cliMessage ?? Self.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("URL Scheme") {
                LabeledContent("Scheme", value: "kadr://")
                Text("Every command the tool takes also works as a URL, so Raycast, "
                    + "Alfred and Shortcuts can drive Kadr. CleanShot's verb names are "
                    + "accepted as aliases. Run `kadr help` in Terminal for the full list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            StudioStorageSection()

            Section {
                Toggle("Include Kadr overlays in captures", isOn: includeOverlays)
                Text("Off keeps cards, the recording bar and the HUD out of screenshots and recordings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Reset") {
                Button("Reset All Settings…", role: .destructive) {
                    showsResetConfirmation = true
                }
                Text("Puts every preference back to its default. Your captures and "
                    + "history are left alone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Remove All Kadr Data…", role: .destructive) {
                    showsRemoveDataConfirmation = true
                }
                Text("Deletes History, recording sessions, pins, diagnostics and every "
                    + "setting, then quits. Captures you saved to your own folders are kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button("Export Diagnostics…") {
                    Task { await AppDelegate.shared.exportDiagnostics() }
                }
                Text("Writes a zip of Kadr's log, crash reports and this Mac's setup — no "
                    + "captures or file names — and shows it in Finder. Nothing is sent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsFormChrome()
        .task { refresh() }
        .confirmationDialog(
            "Reset all settings to their defaults?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
                HotkeyCenter.restoreAll()
                AppDelegate.shared.reapplySettingsAfterReset()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove all Kadr data and quit?",
            isPresented: $showsRemoveDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove and Quit", role: .destructive) {
                AppDelegate.shared.removeAllKadrData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("History, pins, settings and every recording session are deleted. A session "
                + "that holds the only copy of a recording deletes that recording too. This "
                + "cannot be undone.")
        }
    }

    private static let explanation =
        "Installs a `kadr` command that talks to the running app. "
            + "It links to the tool inside Kadr.app, so it updates when Kadr does."

    private func refresh() {
        isInstalled = installer.isInstalled
    }

    private var includeOverlays: Binding<Bool> {
        Binding(
            get: { settings.includesOverlaysInCaptures },
            set: { value in
                settings.includesOverlaysInCaptures = value
                CaptureVisibility.includesOverlays = value
                CaptureExclusionRegistry.shared.refresh()
            }
        )
    }

    private func apply(_ outcome: CLIInstaller.Outcome) {
        switch outcome {
        case let .installed(url):
            cliMessage = "Installed at \(url.path)."
        case let .installedNeedsPath(url):
            cliMessage = "Installed at \(url.path). Add \(url.deletingLastPathComponent().path) to your PATH."
        case let .failed(message):
            cliMessage = message
        }
        refresh()
    }
}
