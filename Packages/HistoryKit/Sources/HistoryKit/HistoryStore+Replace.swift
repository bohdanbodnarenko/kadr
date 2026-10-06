import Foundation
import GRDB
import Shared

/// New pixels for a capture History already holds (docs/18 OUT-4).
///
/// An editor save or a card's rotate used to re-ingest the result as a brand-new capture,
/// dated "now", with no app name and nothing indexed, while the original row was deleted —
/// so editing a capture moved it to the top of History and lost what History knew about
/// it. Replacing keeps the row: its id, capture date and app name stay, and only the
/// content, size and thumbnail change.
public extension HistoryStore {
    /// Points the record holding `previousHash` at the file at `sourceURL`.
    ///
    /// - Returns: the updated record, or nil when no record holds `previousHash` — the
    ///   caller then ingests as usual.
    @discardableResult
    func replaceContent(
        previousHash: String,
        with sourceURL: URL,
        pixelSize: PixelSize,
        originalFilename: String? = nil
    ) async throws -> HistoryRecord? {
        guard let existing = try await read({ db in
            try HistoryRecord.filter(sql: "content_hash = ?", arguments: [previousHash]).fetchOne(db)
        }) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw HistoryError.sourceMissing(sourceURL)
        }

        let hash = try HistoryContentAddress.hash(of: sourceURL)
        guard hash != previousHash else { return existing }
        let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let captureURL = layout.captureURL(hash: hash, fileExtension: fileExtension)
        try HistoryContentAddress.install(from: sourceURL, to: captureURL)
        let thumbURL = layout.thumbnailURL(hash: hash)
        try HistoryThumbnailWriter.write(from: sourceURL, to: thumbURL)

        var updated = existing
        updated.contentHash = hash
        updated.relativePath = layout.relativePath(for: captureURL)
        updated.thumbnailRelativePath = layout.relativePath(for: thumbURL)
        updated.width = pixelSize.width
        updated.height = pixelSize.height
        updated.byteSize = Int64((try? captureURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        updated.lastAccessedAt = Date()
        if let originalFilename, !Self.sanitisedFilename(originalFilename).isEmpty {
            updated.originalFilename = Self.sanitisedFilename(originalFilename)
        }

        let persisted = updated
        try HistorySidecar.write(persisted, to: layout.sidecarURL(id: persisted.id))
        try await write { db in
            try persisted.update(db)
            // The text changed with the pixels; the indexer reads it again.
            try db.execute(sql: "DELETE FROM capture_fts WHERE id = ?", arguments: [persisted.id.uuidString])
        }

        // The old bytes go once nothing else points at them.
        let stillUsed = try await read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM capture_records WHERE content_hash = ?",
                arguments: [previousHash]
            ) ?? 0
        }
        if stillUsed == 0 {
            try? FileManager.default.removeItem(at: fileURL(for: existing))
            try? FileManager.default.removeItem(at: thumbnailFileURL(for: existing))
        }
        return persisted
    }
}
