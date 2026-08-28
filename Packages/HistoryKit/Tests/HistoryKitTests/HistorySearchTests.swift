import Foundation
import Shared
import Testing
@testable import HistoryKit

/// The FTS5 query the user's typing turns into (docs/03 §5 P3).
///
/// Table-driven because the failure mode is not "wrong results" but "SQLite raises a
/// syntax error and the search field goes dead" — and the inputs that do that are exactly
/// the ones people type: a stray quote, a hyphen, a URL.
@Suite("History search queries")
struct HistorySearchQueryTests {
    @Test("A word becomes a quoted prefix term")
    func singleWord() {
        #expect(HistorySearchQuery.expression(for: "stripe") == "\"stripe\"*")
    }

    @Test("Several words become several terms, which FTS5 ANDs")
    func severalWords() {
        #expect(HistorySearchQuery.expression(for: "stripe error") == "\"stripe\"* \"error\"*")
    }

    @Test("Nothing to search for is nil, not an empty match", arguments: ["", "   ", "-", "!!!", "*"])
    func emptyQueries(text: String) {
        #expect(HistorySearchQuery.expression(for: text) == nil)
    }

    /// Every one of these is a syntax error if passed to `MATCH` unquoted.
    @Test("Operators and punctuation are searched for literally", arguments: [
        "AND", "OR", "NOT", "NEAR", "^token", "a:b"
    ])
    func operatorsAreLiterals(text: String) throws {
        let expression = try #require(HistorySearchQuery.expression(for: text))
        #expect(expression.hasPrefix("\""))
        #expect(expression.hasSuffix("\"*"))
    }

    @Test("An unbalanced quote cannot break the query")
    func unbalancedQuote() {
        // Doubling is FTS5's own escape, so the term stays one literal token.
        #expect(HistorySearchQuery.expression(for: "\"error") == "\"error\"*")
    }

    @Test("A URL splits into the parts someone would search for")
    func urlSplits() {
        #expect(HistorySearchQuery.tokens(in: "stripe.com/errors?id=4") == ["stripe", "com", "errors", "id", "4"])
    }
}

/// Searching and indexing against a real SQLite file (docs/03 §5 P3, docs/06 M20).
@Suite("History index")
struct HistoryIndexTests {
    private func makeStore() throws -> (HistoryStore, URL) {
        let root = try makeHistoryRoot()
        return try (HistoryStore.open(root: root), root)
    }

    @Test("Nothing is indexed until something indexes it")
    func startsEmpty() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.ingest(ingestDraft(seed: 1))
        #expect(try await store.indexedCount() == 0)
        #expect(try await store.unindexedCount() == 1)
        #expect(try await store.search("anything").isEmpty)
    }

    @Test("An indexed capture is findable by its text")
    func findsByText() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try await store.ingest(ingestDraft(seed: 2))
        try await store.index(id: record.id, text: "Stripe error 402 payment required", applicationName: "Safari")

        let hits = try await store.search("stripe")
        #expect(hits.map(\.id) == [record.id])
        #expect(try await store.search("402").map(\.id) == [record.id])
        // Prefix matching, so results appear while the user is still typing.
        #expect(try await store.search("paym").map(\.id) == [record.id])
        #expect(try await store.search("refund").isEmpty)
    }

    @Test("The app a capture came from is searchable too")
    func findsByApplication() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try await store.ingest(ingestDraft(seed: 3))
        try await store.index(id: record.id, text: "", applicationName: "Xcode")
        #expect(try await store.search("xcode").map(\.id) == [record.id])
    }

    @Test("Search still honours the type filter")
    func searchHonoursFilters() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let image = try await store.ingest(ingestDraft(seed: 4))
        let video = try await store.ingest(ingestDraft(seed: 5, kind: .video))
        try await store.index(id: image.id, text: "shared word", applicationName: nil)
        try await store.index(id: video.id, text: "shared word", applicationName: nil)

        #expect(try await store.search("shared").count == 2)
        let images = try await store.search("shared", filter: HistoryFilter(kind: .image))
        #expect(images.map(\.id) == [image.id])
    }

    @Test("An empty search falls back to browsing, so the grid never goes blank")
    func emptySearchBrowses() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.ingest(ingestDraft(seed: 6))
        try await store.ingest(ingestDraft(seed: 7))
        #expect(try await store.search("   ").count == 2)
    }

    @Test("A capture with nothing readable is not re-read on every pass")
    func emptyTextStillCounts() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try await store.ingest(ingestDraft(seed: 8))
        try await store.index(id: record.id, text: "", applicationName: nil)
        #expect(try await store.unindexedCount() == 0)
        #expect(try await store.indexCandidates(limit: 10).isEmpty)
    }

    @Test("Recordings are never queued for OCR")
    func recordingsAreNotCandidates() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.ingest(ingestDraft(seed: 9, kind: .video))
        #expect(try await store.indexCandidates(limit: 10).isEmpty)
        #expect(try await store.unindexedCount() == 0)
    }

    @Test("Candidates carry the file the helper has to open")
    func candidatesCarryPaths() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try await store.ingest(ingestDraft(seed: 10))
        let candidates = try await store.indexCandidates(limit: 10)
        #expect(candidates.count == 1)
        #expect(candidates.first?.id == record.id)
        #expect(FileManager.default.fileExists(atPath: candidates[0].fileURL.path))
        #expect(candidates.first?.applicationName == "Tester")
    }

    @Test("Deleting a capture takes its index row with it")
    func deleteClearsIndex() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try await store.ingest(ingestDraft(seed: 11))
        try await store.index(id: record.id, text: "secret", applicationName: nil)
        _ = try await store.delete(ids: [record.id])

        #expect(try await store.indexedCount() == 0)
        #expect(try await store.search("secret").isEmpty)
    }

    @Test("Opting out clears everything that was learned")
    func clearIndex() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try await store.ingest(ingestDraft(seed: 12))
        try await store.index(id: record.id, text: "private note", applicationName: nil)
        try await store.clearIndex()

        #expect(try await store.indexedCount() == 0)
        #expect(try await store.search("private").isEmpty)
        // And the capture goes back on the queue, so opting in again re-reads it.
        #expect(try await store.unindexedCount() == 1)
    }

    @Test("Indexing the same capture twice does not duplicate it")
    func reindexReplaces() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try await store.ingest(ingestDraft(seed: 13))
        try await store.index(id: record.id, text: "first", applicationName: nil)
        try await store.index(id: record.id, text: "second", applicationName: nil)

        #expect(try await store.indexedCount() == 1)
        #expect(try await store.search("first").isEmpty)
        #expect(try await store.search("second").map(\.id) == [record.id])
    }
}
