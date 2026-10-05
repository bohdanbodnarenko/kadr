import Foundation
import HistoryKit
import os
import Shared

/// Split from `HistoryController.swift` for the file-length cap: deletes that wait out their
/// Undo window, and what the user is told when the library cannot be opened.
extension HistoryController {
    /// Moves library items to the Trash, with an Undo (docs/14 UX-22, docs/17 T-OUT-7).
    ///
    /// The rows go at once and the banner offers Undo; the delete itself waits out the
    /// Undo window. It has to: the library's files are named by hash, so once they are in
    /// the Trash, Finder's Put Back restores a `3fa9c1….png` and never the History row.
    /// Retention eviction stays permanent.
    func moveToTrash(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        let batch = UUID()
        let hidden = Set(ids)
        pendingTrash[batch] = PendingTrash(ids: hidden, commit: Task { [weak self] in
            try? await Task.sleep(for: FeedbackStatus.undoWindow + .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.commitTrash(batch)
        })
        records.removeAll { hidden.contains($0.id) }
        recent.removeAll { hidden.contains($0.id) }
        let message = ids.count == 1
            ? String(localized: "Moved to Trash")
            : String(localized: "Moved \(ids.count) captures to Trash")
        FailurePresenter.present(.undoable(message) { [weak self] in
            Task { await self?.undoTrash(batch) }
        })
    }

    /// Puts a batch back, before its delete has run.
    func undoTrash(_ batch: UUID) async {
        guard let pending = pendingTrash.removeValue(forKey: batch) else { return }
        pending.commit.cancel()
        logger.info("Put \(pending.ids.count, privacy: .public) history item(s) back")
        await reload(filter: currentFilter)
    }

    /// Whether a History delete is still waiting out its Undo window.
    var hasPendingTrash: Bool {
        !pendingTrash.isEmpty
    }

    /// Runs every pending delete now, for quitting (docs/18 OUT-5).
    func settlePendingTrash() async {
        for batch in Array(pendingTrash.keys) {
            pendingTrash[batch]?.commit.cancel()
            await commitTrash(batch)
        }
    }

    /// Deletes a batch whose Undo window has passed.
    func commitTrash(_ batch: UUID) async {
        guard let pending = pendingTrash.removeValue(forKey: batch) else { return }
        await openIfNeeded()
        guard let store else { return }
        do {
            _ = try await store.delete(ids: Array(pending.ids), fileDisposition: .trash)
            usage = try await store.storageUsage()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            logger.error("Could not delete history items: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Said once per launch: every History read retries the open, and a banner per attempt
    /// would bury the screen (docs/18 X-5a; the rebuild is OUT-3).
    func reportOpenFailure(_ error: any Error) {
        guard !hasReportedOpenFailure else {
            logger.error("Could not open history: \(error.localizedDescription, privacy: .public)")
            return
        }
        hasReportedOpenFailure = true
        FailurePresenter.report(
            "Kadr could not open or rebuild your History. Captures are still saved, but History stays empty.",
            detail: error.localizedDescription,
            logger: logger,
            retryTitle: String(localized: "Rebuild Library"),
            retry: { [weak self] in
                guard let self else { return }
                hasReportedOpenFailure = false
                Task { await self.openIfNeeded() }
            }
        )
    }

    /// Says the library was rebuilt, once, so a History that comes back with fewer
    /// captures (one whose file is gone) is not a mystery.
    func reportRecovery(count: Int) {
        logger.notice("History database was unreadable; rebuilt \(count, privacy: .public) records")
        FailurePresenter.present(FeedbackStatus(
            kind: .warning,
            message: String(localized: "History could not be read, so Kadr rebuilt it: \(count) captures recovered.")
                + " " + String(localized: "The unreadable file was kept beside it.")
        ))
    }

    /// Puts a fresh capture at the top of an open, newest-first grid it belongs in, so the
    /// window does not go stale until the next reload (docs/18 OUT-9). Other sorts and a
    /// search pick it up when they next query; inserting mid-list would move the rows under
    /// the pointer.
    func showInOpenWindow(_ record: HistoryRecord) {
        guard isWindowOpen, !isSearching, currentFilter.sort == .newest,
              HistoryStore.matches(record, filter: currentFilter),
              !records.contains(where: { $0.id == record.id })
        else { return }
        records.insert(record, at: 0)
    }
}
