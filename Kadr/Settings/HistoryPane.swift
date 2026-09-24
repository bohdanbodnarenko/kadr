import HistoryKit
import SettingsKit
import SwiftUI

/// History settings (docs/03 §5, §8.3): retention and the library size cap.
struct HistoryPane: View {
    @Bindable var settings: AppSettings
    var history: HistoryController?

    /// A retention or cap change that would delete captures, waiting for the user to say
    /// so (docs/17 T-OUT-4). Changing a picker used to delete on the spot, permanently.
    @State private var pendingDeletion: PendingRetentionChange?
    /// Set while a cancelled change is being put back, so the revert is not reviewed too.
    @State private var isReverting = false

    var body: some View {
        Form {
            Section {
                Picker("Keep captures", selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases, id: \.self) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                Text("Session-only clears the library the next time Kadr launches. "
                    + "Deleting from History always removes the file Kadr stored.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Search the text in captures", isOn: $settings.historyIndexesText)
                Text("Kadr reads your captures so History can be searched by what is in "
                    + "them. It happens in a helper process, only while you are on mains "
                    + "power, and nothing ever leaves this Mac. Turning it off deletes "
                    + "everything Kadr has read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Library size limit", selection: $settings.historySizeCap) {
                    ForEach(HistorySizeCap.allCases, id: \.self) { cap in
                        Text(cap.title).tag(cap)
                    }
                }
                Text("When the library is over the limit, the captures you have not "
                    + "opened or dragged out recently are removed first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsFormChrome()
        .onChange(of: settings.historyRetention) { old, _ in
            review { settings.historyRetention = old }
        }
        .onChange(of: settings.historySizeCap) { old, _ in
            review { settings.historySizeCap = old }
        }
        .onChange(of: settings.historyIndexesText) { _, _ in history?.applySettingsChange() }
        .alert(
            pendingDeletion?.title ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: {
                    if !$0 {
                        cancelPendingDeletion()
                    }
                }
            ),
            presenting: pendingDeletion
        ) { _ in
            Button("Delete", role: .destructive) {
                pendingDeletion = nil
                history?.applySettingsChange()
            }
            Button("Cancel", role: .cancel) {
                cancelPendingDeletion()
            }
        } message: { _ in
            Text("They are removed from History and the files Kadr stored for them are deleted. "
                + "This can't be undone.")
        }
    }

    /// Asks before a change that deletes, and applies one that does not.
    private func review(revert: @escaping () -> Void) {
        if isReverting {
            isReverting = false
            return
        }
        guard let history else { return }
        let retention = settings.historyRetention
        let cap = settings.historySizeCap
        Task {
            let plan = await history.retentionPreview(retention: retention, sizeCap: cap)
            guard let plan, !plan.ids.isEmpty else {
                history.applySettingsChange()
                return
            }
            pendingDeletion = PendingRetentionChange(count: plan.count, bytes: plan.bytes, revert: revert)
        }
    }

    private func cancelPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        isReverting = true
        pending.revert()
    }
}

/// What a retention change would delete, for its confirmation.
struct PendingRetentionChange {
    let count: Int
    let bytes: Int64
    let revert: () -> Void

    var title: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return count == 1
            ? String(localized: "Permanently delete 1 capture (\(size))?")
            : String(localized: "Permanently delete \(count) captures (\(size))?")
    }
}
