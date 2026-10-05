import Foundation
import HistoryKit
import os
import Shared

extension HistoryController {
    /// New pixels for a capture History already holds: an editor save over the file, or a
    /// rotate on its card (docs/18 OUT-4).
    ///
    /// The row keeps its id, capture date and app name. When History has no row for
    /// `previousHash` and `ingestIfMissing` is set, `content` is ingested instead, so an
    /// editor save is never lost. A card's rotate passes false: its capture's own ingest
    /// may still be queued, and reads the rotated file when it runs.
    func replaceContent(previousHash: String?, content fallback: HistoryIngest, ingestIfMissing: Bool) {
        Task { [weak self] in
            guard let self else { return }
            await openIfNeeded()
            guard let store else { return }
            if let previousHash {
                do {
                    if let updated = try await store.replaceContent(
                        previousHash: previousHash,
                        with: fallback.sourceURL,
                        pixelSize: fallback.pixelSize,
                        originalFilename: fallback.originalFilename
                    ) {
                        replaceRow(updated)
                        usage = await (try? store.storageUsage()) ?? usage
                        startIndexingIfAllowed()
                        return
                    }
                } catch {
                    logger.error("History replace failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if ingestIfMissing {
                ingest(fallback)
            }
        }
    }

    /// Swaps a row in place in the grid and the menu-bar strip.
    private func replaceRow(_ record: HistoryRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        }
        if let index = recent.firstIndex(where: { $0.id == record.id }) {
            recent[index] = record
        }
    }
}
