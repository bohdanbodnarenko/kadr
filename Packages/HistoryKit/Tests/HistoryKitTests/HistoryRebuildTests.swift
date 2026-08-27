import Foundation
import Testing
@testable import HistoryKit

@Suite("History index rebuild", .serialized)
struct HistoryRebuildTests {
    @Test("The SQLite index is disposable and rebuilds from files plus sidecar JSON")
    func rebuildFromSidecars() async throws {
        let root = try makeHistoryRoot()
        let first: HistoryRecord
        let second: HistoryRecord
        do {
            let store = try HistoryStore.open(root: root)
            first = try await store.ingest(ingestDraft(seed: 1))
            second = try await store.ingest(ingestDraft(seed: 2))
        }

        let layout = HistoryLayout(root: root)
        try FileManager.default.removeItem(at: layout.databaseURL)
        for extra in ["history.sqlite-wal", "history.sqlite-shm"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(extra))
        }

        let rebuilt = try HistoryStore.open(root: root)
        #expect(try await rebuilt.storageUsage().itemCount == 0, "a missing DB starts empty")

        let count = try await rebuilt.rebuild()
        #expect(count == 2)

        let recent = try await rebuilt.recent(limit: 8)
        let names = Set(recent.map(\.originalFilename))
        #expect(names == ["capture-1.png", "capture-2.png"])
        #expect(FileManager.default.fileExists(atPath: rebuilt.fileURL(for: first).path))
        #expect(FileManager.default.fileExists(atPath: rebuilt.fileURL(for: second).path))
    }

    @Test("Rebuild drops sidecars whose media file is gone")
    func rebuildSkipsMissingFiles() async throws {
        let root = try makeHistoryRoot()
        let store = try HistoryStore.open(root: root)
        let record = try await store.ingest(ingestDraft(seed: 4))
        try FileManager.default.removeItem(at: store.fileURL(for: record))

        let count = try await store.rebuild()

        #expect(count == 0)
        #expect(try await store.storageUsage().itemCount == 0)
        #expect(!FileManager.default.fileExists(atPath: store.layout.sidecarURL(id: record.id).path))
    }
}
