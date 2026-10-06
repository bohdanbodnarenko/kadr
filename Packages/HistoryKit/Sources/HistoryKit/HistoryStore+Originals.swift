import Foundation
import GRDB

/// The link from a library item back to the user's own file, and its name (docs/18 OUT-6).
public extension HistoryStore {
    /// Records where the capture with `contentHash` now lives outside the library: it was
    /// saved from staging, or moved by Save As. Nil clears it.
    func setOriginalPath(_ url: URL?, forContentHash contentHash: String) async throws {
        let path = url?.standardizedFileURL.path
        let bookmark = url.flatMap { try? $0.bookmarkData() }
        let records = try await read { db in
            try HistoryRecord.filter(sql: "content_hash = ?", arguments: [contentHash]).fetchAll(db)
        }
        for var record in records where record.originalPath != path || record.originalBookmark != bookmark {
            record.originalPath = path
            record.originalBookmark = bookmark
            let persisted = record
            try HistorySidecar.write(persisted, to: layout.sidecarURL(id: persisted.id))
            try await write { db in
                try persisted.update(db)
            }
        }
    }

    /// The user's own file for `record`: where Kadr last saw it, or where its bookmark says
    /// it went after a move or rename, as long as it is still the same size. Otherwise nil,
    /// and callers use the library copy.
    nonisolated func originalFile(for record: HistoryRecord) -> URL? {
        Self.originalFile(path: record.originalPath, bookmark: record.originalBookmark, byteSize: record.byteSize)
    }

    internal nonisolated static func originalFile(path: String?, bookmark: Data?, byteSize: Int64) -> URL? {
        func matches(_ url: URL) -> Bool {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
            return Int64(size) == byteSize
        }
        if let path {
            let url = URL(fileURLWithPath: path)
            if matches(url) {
                return url
            }
        }
        guard let bookmark else { return nil }
        var isStale = false
        guard let moved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            bookmarkDataIsStale: &isStale
        ), !moved.path.contains("/.Trash/"), matches(moved) else { return nil }
        return moved
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
