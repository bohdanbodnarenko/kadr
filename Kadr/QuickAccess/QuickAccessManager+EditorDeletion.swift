import Foundation
import os
import Shared

/// Captures the editor moved to the Trash (docs/03 §3).
///
/// Deleting from the editor has to mean what deleting from the card means: the card goes,
/// and so does History's content-addressed copy — otherwise a "deleted" sensitive screenshot
/// sits in App Support until retention expires (docs/07 H5). The editor cannot reach either,
/// so it posts a notice and this does the agent's half.
@MainActor
extension QuickAccessManager {
    /// Listens for the agent's whole life. An observer is not a timer: it costs nothing until
    /// a notice arrives (CLAUDE.md rule 2).
    func watchForEditorDeletions() {
        guard editorDeletionObserver == nil else { return }
        editorDeletionObserver = DistributedNotificationCenter.default().addObserver(
            forName: CaptureDeletionNotice.name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let paths = CaptureDeletionNotice.decode(notification.object) else { return }
            MainActor.assumeIsolated {
                self?.captureWasTrashed(paths)
            }
        }
    }

    /// Drops the card for a capture the editor trashed, and purges History's copy of it.
    ///
    /// Only for a file that is really in a Trash: a notice is a claim from another process,
    /// and one pointing anywhere else is not a deletion.
    func captureWasTrashed(_ paths: CaptureDeletionNotice.Paths) {
        guard CaptureDeletionNotice.isInTrash(paths.trashed) else { return }
        // Hashed from the Trash, where the bytes still are.
        history?.deleteFromLibrary(matching: paths.trashed)

        let original = paths.original.standardizedFileURL
        let removed = items.filter { $0.fileURL.standardizedFileURL == original }
        guard !removed.isEmpty else { return }
        for item in removed {
            dismissCoachTip(for: item)
            items.removeAll { $0.id == item.id }
            forgetTransientState(for: item)
        }
        logger.info("Removed the card for a capture the editor moved to the Trash")
        finishRemoval()
    }
}
