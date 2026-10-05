import Foundation
import Testing
@testable import HistoryKit

/// docs/18 OUT-9: paging after the last row shown neither skips nor repeats rows when the
/// library changes between pages.
@Suite("History keyset paging", .serialized)
struct HistoryPagingTests {
    private func seed(_ store: HistoryStore, count: Int) async throws -> [HistoryRecord] {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var records: [HistoryRecord] = []
        for index in 0 ..< count {
            // Pairs share a timestamp, so the id tiebreak is exercised.
            let when = base.addingTimeInterval(TimeInterval(index / 2) * 60)
            try await records.append(store.ingest(ingestDraft(seed: index, capturedAt: when)))
        }
        return records
    }

    @Test("Pages cover every row exactly once, in every sort", arguments: HistorySort.allCases)
    func coversEveryRow(sort: HistorySort) async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore.open(root: root)
        let seeded = try await seed(store, count: 9)
        let filter = HistoryFilter(sort: sort)

        var seen: [UUID] = []
        var last: HistoryRecord?
        while true {
            let page = try await store.loadPage(filter: filter, after: last, limit: 4)
            guard !page.isEmpty else { break }
            seen += page.map(\.id)
            last = page.last
        }
        #expect(seen.count == seeded.count)
        #expect(Set(seen) == Set(seeded.map(\.id)))
    }

    @Test("A capture added between pages shifts nothing")
    func insertionBetweenPages() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore.open(root: root)
        let seeded = try await seed(store, count: 8)
        let filter = HistoryFilter(sort: .newest)

        let first = try await store.loadPage(filter: filter, after: nil, limit: 4)
        _ = try await store.ingest(ingestDraft(seed: 99, capturedAt: Date(timeIntervalSince1970: 1_900_000_000)))
        let second = try await store.loadPage(filter: filter, after: first.last, limit: 4)

        let shown = first.map(\.id) + second.map(\.id)
        #expect(Set(shown).count == shown.count, "no row twice")
        #expect(Set(shown) == Set(seeded.map(\.id)), "no row skipped")
    }

    @Test("Filter matching agrees with the grid's filters", arguments: [
        (HistoryFilter(), true),
        (HistoryFilter(kind: .image), true),
        (HistoryFilter(kind: .video), false),
        (HistoryFilter(capturedAfter: Date.distantPast), true),
        (HistoryFilter(capturedAfter: Date.distantFuture), false)
    ])
    func matches(filter: HistoryFilter, expected: Bool) throws {
        let record = HistoryRecord(
            contentHash: "x",
            relativePath: "x.png",
            thumbnailRelativePath: "x.jpg",
            kind: .image,
            width: 2,
            height: 2,
            applicationName: nil,
            capturedAt: Date(),
            lastAccessedAt: Date(),
            byteSize: 1,
            originalFilename: "x.png"
        )
        #expect(HistoryStore.matches(record, filter: filter) == expected)
    }
}
