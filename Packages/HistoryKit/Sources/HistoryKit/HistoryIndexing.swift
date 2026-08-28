import Foundation
import GRDB
import Shared

/// One capture waiting to be read (docs/03 §5 P3).
public struct HistoryIndexCandidate: Sendable, Hashable, Codable {
    public var id: UUID
    /// The file to recognise text in.
    public var fileURL: URL
    public var applicationName: String?

    public init(id: UUID, fileURL: URL, applicationName: String?) {
        self.id = id
        self.fileURL = fileURL
        self.applicationName = applicationName
    }
}

public extension HistoryStore {
    /// Full-text search over recognised text and app names (docs/03 §5 P3).
    ///
    /// Ranked by FTS5's own `rank`, then filtered exactly like a browse query so the
    /// type and date pickers keep working while a search is active.
    func search(_ text: String, filter: HistoryFilter = .all, limit: Int = 200) async throws -> [HistoryRecord] {
        guard let expression = HistorySearchQuery.expression(for: text) else {
            return try await loadPage(filter: filter, offset: 0, limit: limit)
        }

        return try await read { db in
            // Two steps rather than a join: FTS5's rank is only available on the virtual
            // table's own query, and the ordering is the point of a search.
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM capture_fts WHERE capture_fts MATCH ? ORDER BY rank LIMIT ?",
                arguments: [expression, limit]
            )
            guard !ids.isEmpty else { return [] }

            var request = HistoryRecord.filter(ids.contains(Column("id")))
            request = Self.apply(filter, to: request)
            let records = try request.fetchAll(db)

            // Put them back in rank order; the SQL above lost it.
            let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            return records.sorted { rank[$0.id.uuidString, default: .max] < rank[$1.id.uuidString, default: .max] }
        }
    }

    /// Captures with no index row yet, newest first (docs/03 §5: index what is retained).
    func indexCandidates(limit: Int) async throws -> [HistoryIndexCandidate] {
        let records: [HistoryRecord] = try await read { db in
            try HistoryRecord
                .filter(sql: "id NOT IN (SELECT id FROM capture_fts)")
                .order(Column("captured_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
        // Recordings are not read: there is no single frame to recognise, and OCR'ing a
        // poster frame would index a title card rather than the content. Projects are
        // zips — the text in one is already indexed from the capture it came from.
        return records
            .filter(\.kind.isReadable)
            .map {
                HistoryIndexCandidate(
                    id: $0.id,
                    fileURL: fileURL(for: $0),
                    applicationName: $0.applicationName
                )
            }
    }

    /// How many captures are still waiting to be read.
    func unindexedCount() async throws -> Int {
        try await read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM capture_records
                WHERE kind NOT IN ('video', 'project') AND id NOT IN (SELECT id FROM capture_fts)
                """
            ) ?? 0
        }
    }

    /// Records the text found in a capture. Empty text still writes a row, so a capture
    /// with nothing readable in it is not read again on every pass.
    func index(id: UUID, text: String, applicationName: String?) async throws {
        try await write { db in
            try db.execute(
                sql: "DELETE FROM capture_fts WHERE id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO capture_fts (id, ocr_text, application_name) VALUES (?, ?, ?)",
                arguments: [id.uuidString, text, applicationName ?? ""]
            )
        }
    }

    /// Drops everything the indexer has learned. Used when the user opts out (docs/03 §5).
    func clearIndex() async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM capture_fts")
        }
    }

    /// Whether anything has been indexed yet, for the "still indexing" hint in the UI.
    func indexedCount() async throws -> Int {
        try await read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_fts") ?? 0
        }
    }
}
