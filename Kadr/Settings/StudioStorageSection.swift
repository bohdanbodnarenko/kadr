import AppKit
import Shared
import StudioCore
import SwiftUI

/// What the studio's sessions are costing, and how to get it back (docs/09 U3.1).
///
/// Sessions are swept automatically once they age out, but only when the footage is still
/// linked from the user's own recording. A session holding the *last* copy of its footage
/// is never swept at any age, because a cleanup routine that deletes recordings is not one.
///
/// That policy is right and it is not self-explaining, so this is where it gets explained —
/// and where somebody who deleted their recordings and wants the disk back can say so
/// explicitly, having been told exactly what they are throwing away.
struct StudioStorageSection: View {
    @State private var lastCopyCount = 0
    @State private var byteCount = 0
    @State private var showsRemoveConfirmation = false

    var body: some View {
        Section("Recording Sessions") {
            LabeledContent("On disk", value: formatted(byteCount))
            Text("Kadr keeps the pointer track and edits beside each recording so it can be "
                + "opened in the studio later. These are cleared automatically after a month "
                + "— but only while your recording still exists, because the copy here is "
                + "otherwise the last one.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if lastCopyCount > 0 {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Remove \(lastCopyCount) Session\(lastCopyCount == 1 ? "" : "s")…", role: .destructive) {
                    showsRemoveConfirmation = true
                }
                Button("Show in Finder") { reveal() }
            }
        }
        .task { refresh() }
        .confirmationDialog(
            // The count is in the title because it is the fact that matters, and a dialog
            // whose title is a question the user answers without reading the body is how
            // somebody deletes recordings by accident.
            "Delete \(lastCopyCount) recording\(lastCopyCount == 1 ? "" : "s")?",
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { removeLastCopies() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kadr has the only copy of \(lastCopyCount == 1 ? "this recording" : "these recordings"). "
                + "Deleting the session deletes the footage with it, and it cannot be recovered.")
        }
    }

    private var warning: String {
        lastCopyCount == 1
            ? "One of these is the only copy of its recording — the file it came from has been "
            + "moved or deleted — so it is kept until you say otherwise."
            : "\(lastCopyCount) of these are the only copies of their recordings — the files they "
            + "came from have been moved or deleted — so they are kept until you say otherwise."
    }

    private func refresh() {
        guard let store = StudioSessionRecorder.store() else { return }
        lastCopyCount = store.sessionsHoldingTheOnlyCopy().count
        byteCount = store.exclusiveByteCount()
    }

    private func reveal() {
        guard let root = StudioSessionRecorder.root() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    private func removeLastCopies() {
        guard let store = StudioSessionRecorder.store() else { return }
        for session in store.sessionsHoldingTheOnlyCopy() {
            try? session.delete()
        }
        refresh()
    }

    /// Bytes as somebody reads them.
    private func formatted(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
