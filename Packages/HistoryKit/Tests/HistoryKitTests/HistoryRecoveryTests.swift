import Foundation
import Testing
@testable import HistoryKit

/// docs/18 OUT-3: an unreadable database is set aside and rebuilt, never left empty.
@Suite("History recovery", .serialized)
struct HistoryRecoveryTests {
    @Test("A corrupted database is moved aside and History rebuilt from the sidecars")
    func corruptedDatabaseRecovers() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try HistoryStore.open(root: root)
            _ = try await store.ingest(ingestDraft(seed: 1))
            _ = try await store.ingest(ingestDraft(seed: 2))
        }
        let layout = HistoryLayout(root: root)
        for extra in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: layout.databaseURL.path + extra))
        }
        try Data("this is not a SQLite database, not even close".utf8).write(to: layout.databaseURL)

        let opening = try await HistoryStore.openRecovering(root: root)

        #expect(opening.recoveredCount == 2)
        let setAside = try #require(opening.setAside)
        #expect(FileManager.default.fileExists(atPath: setAside.path), "the broken file is kept")
        let names = try await Set(opening.store.recent(limit: 8).map(\.originalFilename))
        #expect(names == ["capture-1.png", "capture-2.png"])
    }

    @Test("A healthy database opens with nothing set aside")
    func healthyOpen() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let opening = try await HistoryStore.openRecovering(root: root)
        #expect(opening.setAside == nil)
        #expect(opening.recoveredCount == 0)
    }
}
