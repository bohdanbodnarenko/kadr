import Foundation
import GRDB
import Testing
@testable import HistoryKit

/// docs/18 OUT-6: schema v2 links a library item back to the user's own file.
@Suite("History original path", .serialized)
struct HistoryOriginalPathTests {
    @Test("An ingest records the original, and it survives a rebuild from sidecars")
    func survivesRebuild() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore.open(root: root)
        var draft = try ingestDraft(seed: 1)
        draft.originalURL = draft.sourceURL
        let record = try await store.ingest(draft)
        #expect(record.originalPath == draft.sourceURL.standardizedFileURL.path)
        #expect(store.originalFile(for: record) == URL(fileURLWithPath: record.originalPath ?? ""))

        _ = try await store.rebuild()
        let rebuilt = try #require(try await store.record(id: record.id))
        #expect(rebuilt.originalPath == record.originalPath)
    }

    @Test("A moved or changed original is not offered")
    func staleOriginal() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore.open(root: root)
        let record = try await store.ingest(ingestDraft(seed: 2))
        let elsewhere = try writeTestImage(seed: 3)

        try await store.setOriginalPath(URL(fileURLWithPath: "/nowhere/gone.png"), forContentHash: record.contentHash)
        var updated = try #require(try await store.record(id: record.id))
        #expect(store.originalFile(for: updated) == nil, "a missing file is not offered")

        try await store.setOriginalPath(elsewhere, forContentHash: record.contentHash)
        updated = try #require(try await store.record(id: record.id))
        #expect(updated.originalPath == elsewhere.standardizedFileURL.path)
    }

    @Test("A version 1 sidecar, with no original path, still decodes")
    func oldSidecarDecodes() throws {
        let json = """
        {"version":1,"id":"\(UUID().uuidString)","contentHash":"abc","relativePath":"Captures/a.png",
        "thumbnailRelativePath":"Thumbnails/a.jpg","kind":"image","width":2,"height":2,
        "capturedAt":"2026-01-01T00:00:00Z","lastAccessedAt":"2026-01-01T00:00:00Z",
        "byteSize":10,"originalFilename":"a.png"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(HistorySidecar.self, from: Data(json.utf8))
        #expect(sidecar.record().originalPath == nil)
    }

    @Test("A version 1 database gains the column without losing rows")
    func migratesV1() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = HistoryLayout(root: root)
        try layout.prepare()
        do {
            let pool = try DatabasePool(path: layout.databaseURL.path)
            var v1 = DatabaseMigrator()
            v1.registerMigration("v1-capture-records") { db in
                try db.execute(sql: """
                CREATE TABLE capture_records (id TEXT PRIMARY KEY, content_hash TEXT NOT NULL,
                relative_path TEXT NOT NULL, thumbnail_relative_path TEXT NOT NULL, kind TEXT NOT NULL,
                width INTEGER NOT NULL, height INTEGER NOT NULL, application_name TEXT,
                captured_at DATETIME NOT NULL, last_accessed_at DATETIME NOT NULL,
                byte_size INTEGER NOT NULL, original_filename TEXT NOT NULL);
                CREATE VIRTUAL TABLE capture_fts USING fts5(id UNINDEXED, ocr_text, application_name);
                INSERT INTO capture_records VALUES ('\(UUID().uuidString)', 'h', 'Captures/h.png',
                'Thumbnails/h.jpg', 'image', 1, 1, NULL, '2026-01-01 00:00:00.000',
                '2026-01-01 00:00:00.000', 5, 'old.png');
                """)
            }
            try v1.migrate(pool)
        }

        let store = try HistoryStore.open(root: root)
        let rows = try await store.recent(limit: 8)
        #expect(rows.map(\.originalFilename) == ["old.png"])
        #expect(rows.first?.originalPath == nil)
    }
}
