import Foundation
import GRDB
import Testing
@testable import HistoryKit

/// The library's SQLite footprint in the resident agent (PRD §8).
///
/// GRDB's defaults — five reader connections, each with SQLite's 2 MB page cache — are
/// sized for an app that reads a database all day. The agent reads a page of history when
/// somebody asks, so it opens one reader with a small cache and gives the pages back after
/// the launch pass.
@Suite("History memory tuning")
struct HistoryTuningTests {
    @Test("Tuning never asks for fewer than one reader or one KiB", arguments: [
        (1, 512, 1, 512),
        (0, 0, 1, 1),
        (-3, -10, 1, 1),
        (4, 2048, 4, 2048)
    ])
    func clamps(readers: Int, cache: Int, expectedReaders: Int, expectedCache: Int) {
        let tuning = HistoryStore.Tuning(maximumReaderCount: readers, pageCacheKiB: cache)
        #expect(tuning.maximumReaderCount == expectedReaders)
        #expect(tuning.pageCacheKiB == expectedCache)
    }

    @Test("The agent profile is one reader and half a megabyte")
    func agentProfile() {
        #expect(HistoryStore.Tuning.agent == HistoryStore.Tuning(maximumReaderCount: 1, pageCacheKiB: 512))
    }

    @Test("Every connection is opened with the tuned page cache", arguments: [512, 64, 4096])
    func pageCacheIsApplied(kibibytes: Int) async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore.open(
            root: root,
            tuning: HistoryStore.Tuning(maximumReaderCount: 1, pageCacheKiB: kibibytes)
        )
        let readerCache = try await store.read { db in
            try Int.fetchOne(db, sql: "PRAGMA cache_size")
        }
        let writerCache = try await store.write { db in
            try Int.fetchOne(db, sql: "PRAGMA cache_size")
        }
        #expect(readerCache == -kibibytes)
        #expect(writerCache == -kibibytes)
    }

    @Test("Releasing memory leaves the library readable")
    func releaseMemoryKeepsWorking() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore.open(root: root)
        let record = try await store.ingest(ingestDraft(seed: 7))
        await store.releaseMemory()
        let found = try await store.record(id: record.id)
        #expect(found?.id == record.id)
    }
}
