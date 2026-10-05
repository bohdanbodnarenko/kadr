import AppKit
import ControlKit
import HistoryKit
import os

/// A card deleted a moment ago, still recoverable (docs/17 T-OUT-1, T-OUT-7).
struct PendingCardDeletion {
    let item: QuickAccessItem
    /// Where the Trash put the capture, and its `.kadr` project if it had one.
    let trashedFile: URL
    let trashedProject: URL?
    /// The library's address for the bytes, taken off the main actor: hashing a
    /// multi-gigabyte recording there beach-balled (docs/17 T-OUT-13).
    let contentHash: Task<String?, Never>
    /// Purges the library copy once the Undo window has passed.
    var commit: Task<Void, Never>?
}

/// Card delete, made undoable (docs/17 §5 theme 3).
///
/// ⌫ on a card used to trash the file and purge the History copy on the spot, so one
/// stray key lost the capture for good. Now the file goes to the Trash — where Finder's
/// Put Back also works — the library purge waits out the Undo window, and a banner offers
/// "Moved to Trash · Undo". Undo puts the file back where it was and the card back on
/// the stack.
@MainActor
extension QuickAccessManager {
    /// Whether this card may be deleted. Files Kadr did not create — a History copy, a
    /// file opened through automation or from the clipboard — are only ever hidden
    /// (docs/17 T-OUT-5).
    func canDelete(_ item: QuickAccessItem) -> Bool {
        item.origin.ownsFile
    }

    /// Moves the capture to the Trash as well as hiding the card, with an Undo.
    func delete(_ item: QuickAccessItem) {
        guard canDelete(item), let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let live = items[index]
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: live.fileURL, resultingItemURL: &trashed)
        } catch {
            presentFeedback(.failure(String(localized: "Couldn't move \(live.filename) to the Trash")))
            logger.error("Could not trash a card: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let trashedFile = trashed as URL? else { return }
        let trashedProject = CaptureProject.trashReturningURL(alongside: live.fileURL)

        dismissCoachTip(for: live)
        items.remove(at: index)
        forgetTransientState(for: live)
        logger.info("Moved \(live.filename, privacy: .public) to the Trash")

        commitPendingDeletions()
        var pending = PendingCardDeletion(
            item: live,
            trashedFile: trashedFile,
            trashedProject: trashedProject,
            contentHash: Task.detached(priority: .utility) {
                try? HistoryStore.contentHash(of: trashedFile)
            }
        )
        let id = live.id
        pending.commit = Task { [weak self] in
            try? await Task.sleep(for: FeedbackStatus.undoWindow + .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.commitDeletion(id: id)
        }
        pendingDeletions[id] = pending

        finishRemoval()
        presentFeedback(.undoable(String(localized: "Moved to Trash")) { [weak self] in
            self?.undoDeletion(id: id)
        })
    }

    /// Puts a deleted card's file back and the card back on the stack.
    func undoDeletion(id: UUID) {
        guard let pending = pendingDeletions.removeValue(forKey: id) else { return }
        pending.commit?.cancel()
        dismissFeedback()
        FailurePresenter.dismiss()
        let original = pending.item.fileURL
        do {
            try FileManager.default.createDirectory(
                at: original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: pending.trashedFile, to: original)
            if let project = pending.trashedProject {
                try? FileManager.default.moveItem(at: project, to: CaptureProject.url(alongside: original))
            }
        } catch {
            // Emptied Trash, or something now sits at the old path: say so rather than
            // pretending the Undo worked.
            presentFeedback(.failure(String(localized: "Couldn't put \(pending.item.filename) back")))
            logger.error("Undo delete failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        present(pending.item)
        logger.info("Put \(pending.item.filename, privacy: .public) back")
    }

    /// Purges the library copy of a deletion whose Undo window has passed.
    func commitDeletion(id: UUID) async {
        guard let pending = pendingDeletions.removeValue(forKey: id) else { return }
        // The library keeps its own content-addressed copy, so trashing the file alone left
        // a "deleted" capture in App Support until retention expired — which for a
        // sensitive screenshot is the whole problem (docs/07 H5).
        if let hash = await pending.contentHash.value {
            history?.deleteFromLibrary(contentHash: hash)
        }
    }

    /// Whether a deletion is still waiting out its Undo window.
    var hasPendingDeletions: Bool {
        !pendingDeletions.isEmpty
    }

    /// Settles every pending deletion and waits for it, for quitting: the fire-and-forget
    /// commits of `commitPendingDeletions` never run once the process exits, which left a
    /// "deleted" capture in the library (docs/18 OUT-5).
    func settlePendingDeletions() async {
        for id in Array(pendingDeletions.keys) {
            pendingDeletions[id]?.commit?.cancel()
            await commitDeletion(id: id)
        }
    }

    /// Settles every deletion still inside its Undo window: a new delete, or quitting.
    func commitPendingDeletions() {
        for id in Array(pendingDeletions.keys) {
            pendingDeletions[id]?.commit?.cancel()
            Task { await commitDeletion(id: id) }
        }
    }
}
