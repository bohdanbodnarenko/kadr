import AppKit
import SwiftUI

/// The updates pane (PRD §4, §9).
///
/// Kadr's one network connection gets its own visible switch. The point is not that
/// updates are unusual — it is that this is the *only* thing that talks to the network,
/// and a user who wants a completely offline app should be able to see that and say no.
///
/// It is also where a tester reads out which build they have (docs/17 T-REL-5): the
/// version carries the build number and commit, with a Copy button, and the diagnostic
/// summary is one click away (T-DIAG-1).
struct UpdatesPane: View {
    @Bindable var updater: UpdaterManager
    /// Copies `system.json` as text; injected so the pane does not reach for the delegate.
    var copyDiagnosticSummary: () -> Void = {}

    @State private var copiedVersion = false
    @State private var copiedSummary = false

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)

                Toggle("Receive beta builds", isOn: $updater.receivesBetaBuilds)

                if let version = updater.availableUpdateVersion {
                    // A background check found it and waited quietly; this is one of the
                    // three places it waits (docs/18 SH-3).
                    LabeledContent(String(localized: "Kadr \(version) is available")) {
                        Button("Install…") {
                            updater.checkForUpdates()
                        }
                    }
                }

                Button("Check Now") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
                .help(updater.isUpdatingAvailable
                    ? String(localized: "Check for a newer version of Kadr now.")
                    : String(localized: "Development builds do not update themselves."))

                if let checked = updater.lastUpdateCheckDate {
                    LabeledContent("Last checked") {
                        Text(checked, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text(updater.buildIdentity.displayString)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button(copiedVersion ? "Copied" : "Copy") {
                            copy(updater.buildIdentity.displayString)
                            copiedVersion = true
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Copy version")
                    }
                }
                LabeledContent("Diagnostics") {
                    Button(copiedSummary ? "Copied" : "Copy Diagnostic Summary") {
                        copyDiagnosticSummary()
                        copiedSummary = true
                    }
                    .controlSize(.small)
                    .help("Copies this Mac's setup and Kadr's settings as text, for a bug report. "
                        + "No file names or captures are included.")
                }
                LabeledContent("License") {
                    Text("MIT").foregroundStyle(.secondary)
                }
            }
        }
        .settingsFormChrome()
    }

    private var footer: String {
        var text = String(localized: """
        This is the only thing Kadr sends over the network. There is no account, no analytics \
        and no uploading — sharing is drag-and-drop.
        """)
        if !updater.isUpdatingAvailable {
            text += " " + String(localized: "This is a development build, so it does not check for updates.")
        }
        return text
    }

    private func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
