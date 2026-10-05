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
    /// What choosing "This session only" will clear at the next launch, while the user
    /// decides (docs/18 SH-2). The setting is written only on confirm.
    @State private var pendingSessionOnly: HistoryStorageUsage?

    var body: some View {
        Form {
            Section {
                Picker("Keep captures", selection: retentionChoice) {
                    ForEach(HistoryRetention.allCases, id: \.self) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                .alert(
                    "Clear History the next time Kadr launches?",
                    isPresented: Binding(
                        get: { pendingSessionOnly != nil },
                        set: {
                            if !$0 {
                                pendingSessionOnly = nil
                            }
                        }
                    ),
                    presenting: pendingSessionOnly
                ) { _ in
                    Button("Clear at Next Launch", role: .destructive) {
                        pendingSessionOnly = nil
                        settings.historyRetention = .session
                    }
                    Button("Cancel", role: .cancel) {
                        pendingSessionOnly = nil
                    }
                } message: { usage in
                    Text(PendingRetentionChange.sessionOnlyMessage(for: usage))
                }
                Text("Session-only clears History at the next launch. Deleting from History "
                    + "removes Kadr's stored copy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Search the text in captures", isOn: $settings.historyIndexesText)
                Text("Makes History searchable by the text in your captures. Runs on this "
                    + "Mac only, on mains power. Turning it off deletes what was read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Library size limit", selection: $settings.historySizeCap) {
                    ForEach(HistorySizeCap.allCases, id: \.self) { cap in
                        Text(cap.title).tag(cap)
                    }
                }
                Text("Over the limit, the captures used least recently go first.")
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

    /// The retention picker, held as a draft for "This session only" (docs/18 SH-2).
    ///
    /// Session-only deletes nothing until the next launch, so the preview the other choices
    /// confirm against was always empty and the wipe went unconfirmed. Choosing it now asks
    /// first, with what is in History today, and writes the setting only on confirm.
    private var retentionChoice: Binding<HistoryRetention> {
        Binding(
            get: { settings.historyRetention },
            set: { choice in
                let usage = history?.usage ?? .zero
                if choice == .session, settings.historyRetention != .session, usage.itemCount > 0 {
                    pendingSessionOnly = usage
                } else {
                    settings.historyRetention = choice
                }
            }
        )
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

    /// The body of the session-only confirmation (docs/18 SH-2).
    static func sessionOnlyMessage(for usage: HistoryStorageUsage) -> String {
        let size = ByteCountFormatter.string(fromByteCount: usage.byteCount, countStyle: .file)
        let captures = usage.itemCount == 1
            ? String(localized: "The 1 capture (\(size)) in History now")
            : String(localized: "The \(usage.itemCount) captures (\(size)) in History now")
        let consequence = String(localized: "and everything you capture until then are deleted with their files.")
        return captures + ", " + consequence + " " + String(localized: "This can't be undone.")
    }

    var title: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return count == 1
            ? String(localized: "Permanently delete 1 capture (\(size))?")
            : String(localized: "Permanently delete \(count) captures (\(size))?")
    }
}
