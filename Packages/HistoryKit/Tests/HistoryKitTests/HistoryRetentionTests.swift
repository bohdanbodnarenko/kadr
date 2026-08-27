import Foundation
import Shared
import Testing
@testable import HistoryKit

@Suite("History retention")
struct HistoryRetentionTests {
    @Test("30-day retention deletes older captures and keeps recent ones")
    func thirtyDayCutoff() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try await store.ingest(ingestDraft(seed: 1, capturedAt: now.addingTimeInterval(-40 * 86400)))
        let fresh = try await store.ingest(ingestDraft(seed: 2, capturedAt: now.addingTimeInterval(-2 * 86400)))

        let report = try await store.applyRetention(
            HistoryPolicy(maxAge: 30 * 86400),
            now: now
        )

        #expect(report.deletedCount == 1)
        #expect(try await store.record(id: old.id) == nil)
        #expect(try await store.record(id: fresh.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: old).path))
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: fresh).path))
    }

    @Test("Session-only retention drops captures from before this launch")
    func sessionOnly() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = try await store.ingest(ingestDraft(seed: 1, capturedAt: launch.addingTimeInterval(-60)))
        let current = try await store.ingest(ingestDraft(seed: 2, capturedAt: launch.addingTimeInterval(10)))

        let report = try await store.applyRetention(
            HistoryPolicy(sessionStartedAt: launch),
            now: launch.addingTimeInterval(20)
        )

        #expect(report.deletedCount == 1)
        #expect(try await store.record(id: previous.id) == nil)
        #expect(try await store.record(id: current.id) != nil)
    }

    @Test("A size cap evicts least-recently-used items first")
    func lruSizeCap() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let first = try await store.ingest(ingestDraft(seed: 1, capturedAt: Date(timeIntervalSince1970: 10)))
        let second = try await store.ingest(ingestDraft(seed: 2, capturedAt: Date(timeIntervalSince1970: 20)))
        let third = try await store.ingest(ingestDraft(seed: 3, capturedAt: Date(timeIntervalSince1970: 30)))

        try await store.markAccessed(id: first.id, at: Date(timeIntervalSince1970: 100))
        try await store.markAccessed(id: second.id, at: Date(timeIntervalSince1970: 50))
        try await store.markAccessed(id: third.id, at: Date(timeIntervalSince1970: 90))

        let usage = try await store.storageUsage()
        #expect(usage.itemCount == 3)
        // Cap just under two files: LRU (second) must go, then the next-oldest access.
        let cap = usage.byteCount - second.byteSize - 1
        let report = try await store.applyRetention(HistoryPolicy(sizeCapBytes: cap))

        #expect(report.deletedCount >= 1)
        #expect(try await store.record(id: second.id) == nil, "the least-recently used item should go first")
        let remaining = try await store.storageUsage()
        #expect(remaining.byteCount <= cap)
        #expect(remaining.itemCount < 3)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: second).path))
    }

    @Test("Forever + no cap leaves everything")
    func keepForever() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        try await store.ingest(ingestDraft(seed: 1, capturedAt: Date(timeIntervalSince1970: 1)))
        let report = try await store.applyRetention(.keepForever)
        #expect(report.deletedCount == 0)
        #expect(try await store.storageUsage().itemCount == 1)
    }
}
