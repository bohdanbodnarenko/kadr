import SwiftUI

/// The updates pane (PRD §4, §9).
///
/// Kadr's one network connection gets its own visible switch. The point is not that
/// updates are unusual — it is that this is the *only* thing that talks to the network,
/// and a user who wants a completely offline app should be able to see that and say no.
struct UpdatesPane: View {
    @Bindable var updater: UpdaterManager

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))

                Button("Check Now") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)

                if let checked = updater.lastUpdateCheckDate {
                    LabeledContent("Last checked") {
                        Text(checked, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("This is the only thing Kadr sends over the network. There is no "
                    + "account, no analytics and no uploading — sharing is drag-and-drop.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version") {
                    Text("\(updater.currentVersion) (\(updater.buildNumber))")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Licence") {
                    Text("MIT").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
