import Foundation
import GRDB

/// The link from a library item back to the user's own file, and its name (docs/18 OUT-6).
public extension HistoryStore {
    /// Records where the capture with `contentHash` now lives outside the library: it was
    /// saved from staging, or moved by Save As. Nil clears it.
    func setOriginalPath(_ url: URL?, forContentHash contentHash: String) async throws {
        let path = url?.standardizedFileURL.path
        let records = try await read { db in
            try HistoryRecord.filter(sql: "content_hash = ?", arguments: [contentHash]).fetchAll(db)
        }
        for var record in records where record.originalPath != path {
            record.originalPath = path
            let persisted = record
            try HistorySidecar.write(persisted, to: layout.sidecarURL(id: persisted.id))
            try await write { db in
                try persisted.update(db)
            }
        }
    }

    /// The user's own file for `record`, when it is still where Kadr last saw it and still
    /// the same size; otherwise nil, and callers use the library copy.
    nonisolated func originalFile(for record: HistoryRecord) -> URL? {
        guard let path = record.originalPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              Int64(size) == record.byteSize
        else { return nil }
        return url
    }

    /// Moves a library file to the Trash under `name` rather than its content hash.
    ///
    /// The file is renamed in a private folder first, so the Trash entry carries the name;
    /// if that fails it is trashed as it is, which still removes it.
    internal nonisolated static func trash(_ file: URL, as name: String, in layout: HistoryLayout) {
        let manager = FileManager.default
        let cleaned = sanitisedFilename(name)
        guard !cleaned.isEmpty else {
            try? manager.trashItem(at: file, resultingItemURL: nil)
            return
        }
        let folder = layout.root
            .appendingPathComponent(".Trashing", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let named = folder.appendingPathComponent(cleaned)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.moveItem(at: file, to: named)
            try manager.trashItem(at: named, resultingItemURL: nil)
        } catch {
            if manager.fileExists(atPath: named.path) {
                try? manager.trashItem(at: named, resultingItemURL: nil)
            } else {
                try? manager.trashItem(at: file, resultingItemURL: nil)
            }
        }
        try? manager.removeItem(at: folder)
    }
}
