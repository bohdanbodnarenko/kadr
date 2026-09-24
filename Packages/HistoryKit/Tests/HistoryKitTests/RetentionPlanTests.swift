import Foundation
import Shared
import Testing
@testable import HistoryKit

/// docs/17 T-OUT-4 and T-OUT-8: retention is previewed before it runs, and the size cap
/// can neither evict what was just ingested nor empty the library in one silent pass.
@Suite("Retention plan")
struct RetentionPlanTests {
    @Test("The plan counts what a pass would delete and deletes nothing")
    func planIsReadOnly() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try await store.ingest(ingestDraft(seed: 1, capturedAt: now.addingTimeInterval(-40 * 86400)))
        try await store.ingest(ingestDraft(seed: 2, capturedAt: now))

        let plan = try await store.retentionPlan(HistoryPolicy(maxAge: 30 * 86400), now: now)

        #expect(plan.count == 1)
        #expect(plan.expired == [old.id])
        #expect(plan.bytes == old.byteSize)
        #expect(try await store.storageUsage().itemCount == 2)
    }

    @Test("The pass deletes exactly what the plan said")
    func passMatchesPlan() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        for seed in 1 ... 4 {
            try await store.ingest(ingestDraft(seed: seed, capturedAt: Date(timeIntervalSince1970: TimeInterval(seed))))
        }
        let usage = try await store.storageUsage()
        let policy = HistoryPolicy(sizeCapBytes: usage.byteCount / 2)

        let plan = try await store.retentionPlan(policy)
        let report = try await store.applyRetention(policy)

        #expect(report.deletedCount == plan.count)
        #expect(report.freedBytes == plan.bytes)
        for id in plan.ids {
            #expect(try await store.record(id: id) == nil)
        }
    }

    @Test("A protected record survives a cap it alone exceeds")
    func protectedRecordIsNeverEvicted() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let older = try await store.ingest(ingestDraft(seed: 1, capturedAt: Date(timeIntervalSince1970: 1)))
        let newest = try await store.ingest(ingestDraft(seed: 2, capturedAt: Date(timeIntervalSince1970: 2)))
        // Make the newest the least recently used, so an unprotected pass would take it.
        try await store.markAccessed(id: older.id, at: Date(timeIntervalSince1970: 100))
        try await store.markAccessed(id: newest.id, at: Date(timeIntervalSince1970: 3))

        try await store.applyRetention(HistoryPolicy(sizeCapBytes: 1, protectedIDs: [newest.id]))

        #expect(try await store.record(id: newest.id) != nil)
        #expect(try await store.record(id: older.id) == nil)
    }

    @Test("A cap pass stops at its eviction limit and says so", arguments: [1, 2, 3])
    func evictionLimit(limit: Int) async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        for seed in 1 ... 5 {
            try await store.ingest(ingestDraft(seed: seed, capturedAt: Date(timeIntervalSince1970: TimeInterval(seed))))
        }

        let report = try await store.applyRetention(HistoryPolicy(sizeCapBytes: 1, maxSizeCapEvictions: limit))

        #expect(report.deletedCount == limit)
        #expect(report.stoppedAtEvictionLimit)
        #expect(try await store.storageUsage().itemCount == 5 - limit)
    }

    @Test("Expiry is not subject to the eviction limit")
    func expiryIgnoresLimit() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for seed in 1 ... 3 {
            try await store.ingest(ingestDraft(seed: seed, capturedAt: now.addingTimeInterval(-40 * 86400)))
        }

        let report = try await store.applyRetention(
            HistoryPolicy(maxAge: 30 * 86400, maxSizeCapEvictions: 1),
            now: now
        )

        #expect(report.deletedCount == 3)
        #expect(!report.stoppedAtEvictionLimit)
    }
}

/// docs/17 T-OUT-13: search caps its results after the type filter, not before.
@Suite("Search cap")
struct SearchCapTests {
    @Test("A filtered search finds a match that more than `limit` other hits outrank")
    func filterBeforeCap() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        for seed in 1 ... 3 {
            let image = try await store.ingest(ingestDraft(seed: seed))
            try await store.index(id: image.id, text: "invoice invoice invoice", applicationName: nil)
        }
        let video = try await store.ingest(ingestDraft(seed: 9, kind: .video))
        try await store.index(
            id: video.id,
            text: "invoice among many other words that dilute its rank",
            applicationName: nil
        )

        let hits = try await store.search("invoice", filter: HistoryFilter(kind: .video), limit: 2)

        #expect(hits.map(\.id) == [video.id])
    }
}

/// docs/17 T-OUT-10: a History name becomes a filename on export, drag and copy.
@Suite("Rename sanitising")
struct RenameSanitisingTests {
    @Test("Names are made safe to use as filenames", arguments: [
        ("../../etc/passwd", "etcpasswd"),
        ("Q3: plan/final.png", "Q3 planfinal.png"),
        (".hidden", "hidden"),
        ("  Receipt  ", "Receipt")
    ])
    func sanitised(input: String, expected: String) {
        #expect(HistoryStore.sanitisedFilename(input) == expected)
    }

    @Test("Rename stores the sanitised name")
    func renameSanitises() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let record = try await store.ingest(ingestDraft(seed: 1))
        try await store.rename(id: record.id, to: "a/b.png")
        #expect(try await store.record(id: record.id)?.originalFilename == "ab.png")
    }
}
