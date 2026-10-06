import Foundation
import GRDB

/// Schema for the disposable index (docs/04 §9, §12).
///
/// FTS5 is created empty: P3 search fills it from the helper process, never from the
/// agent at idle (docs/03 §5).
enum HistoryDatabase {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-capture-records") { db in
            try db.create(table: "capture_records") { table in
                table.column("id", .text).primaryKey()
                table.column("content_hash", .text).notNull().indexed()
                table.column("relative_path", .text).notNull()
                table.column("thumbnail_relative_path", .text).notNull()
                table.column("kind", .text).notNull().indexed()
                table.column("width", .integer).notNull()
                table.column("height", .integer).notNull()
                table.column("application_name", .text)
                table.column("captured_at", .datetime).notNull().indexed()
                table.column("last_accessed_at", .datetime).notNull().indexed()
                table.column("byte_size", .integer).notNull()
                table.column("original_filename", .text).notNull()
            }

            // Stub for P3: OCR text + app names. Unpopulated in M16 so the agent pays
            // nothing at idle for an index it does not yet fill.
            try db.create(virtualTable: "capture_fts", using: FTS5()) { table in
                table.column("id").notIndexed()
                table.column("ocr_text")
                table.column("application_name")
            }
        }
        // v2: where the capture lives outside the library, so Reveal, Pin and the Trash
        // can use the user's own file and its real name rather than a hash (docs/18 OUT-6).
        migrator.registerMigration("v2-original-path") { db in
            try db.alter(table: "capture_records") { table in
                table.add(column: "original_path", .text)
            }
        }
        // v3: a bookmark to that file, so a capture the user moved or renamed in Finder is
        // still found, where the path alone went stale (docs/18 OUT-6).
        migrator.registerMigration("v3-original-bookmark") { db in
            try db.alter(table: "capture_records") { table in
                table.add(column: "original_bookmark", .blob)
            }
        }
        return migrator
    }

    static func makePool(at url: URL, tuning: HistoryStore.Tuning) throws -> DatabasePool {
        var config = Configuration()
        config.busyMode = .timeout(5)
        // One reader: the agent reads the library a page at a time, and every extra reader
        // is its own SQLite connection with its own page cache (PRD §8).
        config.maximumReaderCount = tuning.maximumReaderCount
        let cacheSize = -tuning.pageCacheKiB
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            // Negative means KiB. SQLite's default is 2 MB per connection, which an index
            // of a few thousand rows never needs and the agent's idle budget cannot spare.
            try db.execute(sql: "PRAGMA cache_size = \(cacheSize)")
        }
        return try DatabasePool(path: url.path, configuration: config)
    }
}

extension HistoryRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "capture_records"

    public init(row: Row) {
        id = UUID(uuidString: row["id"]) ?? UUID()
        contentHash = row["content_hash"]
        relativePath = row["relative_path"]
        thumbnailRelativePath = row["thumbnail_relative_path"]
        kind = HistoryItemKind(rawValue: row["kind"]) ?? .image
        width = row["width"]
        height = row["height"]
        applicationName = row["application_name"]
        capturedAt = row["captured_at"]
        lastAccessedAt = row["last_accessed_at"]
        byteSize = row["byte_size"]
        originalFilename = row["original_filename"]
        originalPath = row["original_path"]
        originalBookmark = row["original_bookmark"]
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["content_hash"] = contentHash
        container["relative_path"] = relativePath
        container["thumbnail_relative_path"] = thumbnailRelativePath
        container["kind"] = kind.rawValue
        container["width"] = width
        container["height"] = height
        container["application_name"] = applicationName
        container["captured_at"] = capturedAt
        container["last_accessed_at"] = lastAccessedAt
        container["byte_size"] = byteSize
        container["original_filename"] = originalFilename
        container["original_path"] = originalPath
        container["original_bookmark"] = originalBookmark
    }
}
