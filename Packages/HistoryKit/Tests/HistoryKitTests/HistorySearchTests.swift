import CoreGraphics
import Foundation
import ImageIO
import Shared
import Testing
import UniformTypeIdentifiers
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

    @Test("A recording is findable by the name shown in History")
    func findsByOriginalFilename() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try await store.ingest(ingestDraft(seed: 20, kind: .video))
        try await store.rename(id: record.id, to: "Onboarding walkthrough.mp4")

        let hits = try await store.search("Onboarding")
        #expect(hits.map(\.id) == [record.id])
        #expect(try await store.search("walkthrough").map(\.id) == [record.id])
        #expect(try await store.search("absent").isEmpty)
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

/// Deleting by content, not by row (docs/03 §5, docs/07 H5).
///
/// The privacy case the review found: a capture "deleted" from the overlay card was
/// trashed on disk but left behind in the library's content-addressed store, where it sat
/// until retention expired.
@Suite("Deleting by content")
struct HistoryContentDeleteTests {
    private func makeStore() throws -> (HistoryStore, URL) {
        let root = try makeHistoryRoot()
        return try (HistoryStore.open(root: root), root)
    }

    @Test("Deleting by file removes the library's copy of it")
    func deleteByFile() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = try ingestDraft(seed: 1)
        let record = try await store.ingest(draft)
        #expect(try await store.storageUsage().itemCount == 1)

        // The source file the card still points at, not the library's own copy.
        let report = try await store.delete(fileMatching: draft.sourceURL)

        #expect(report.deletedCount == 1)
        #expect(try await store.storageUsage().itemCount == 0)
        #expect(try await store.record(id: record.id) == nil)
        #expect(
            !FileManager.default.fileExists(atPath: store.fileURL(for: record).path),
            "the library copy is what made a deleted capture recoverable"
        )
    }

    @Test("Every record sharing those bytes goes, not just one")
    func deleteRemovesEveryCopy() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // The same capture ingested twice is one file and two records.
        let draft = try ingestDraft(seed: 2)
        _ = try await store.ingest(draft)
        _ = try await store.ingest(draft)
        #expect(try await store.storageUsage().itemCount == 2)

        let report = try await store.delete(fileMatching: draft.sourceURL)
        #expect(report.deletedCount == 2)
        #expect(try await store.storageUsage().itemCount == 0)
    }

    @Test("Deleting a file the library never held is a no-op, not an error")
    func deleteUnknownFile() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await store.ingest(ingestDraft(seed: 3))
        let stranger = try writeTestImage(seed: 999)
        defer { try? FileManager.default.removeItem(at: stranger) }

        let report = try await store.delete(fileMatching: stranger)
        #expect(report.deletedCount == 0)
        #expect(try await store.storageUsage().itemCount == 1)
    }

    @Test("A deleted capture also leaves the search index")
    func deleteClearsTheIndex() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = try ingestDraft(seed: 4)
        let record = try await store.ingest(draft)
        try await store.index(id: record.id, text: "bank statement", applicationName: nil)
        #expect(try await store.search("bank").count == 1)

        _ = try await store.delete(fileMatching: draft.sourceURL)
        #expect(try await store.search("bank").isEmpty)
    }
}

/// Scratch files handed to an ingest (docs/07 LOW, docs/09 U0.5).
///
/// A recording cannot be thumbnailed by ImageIO, so a poster frame is rendered to a
/// temporary JPEG and handed over. Nothing deleted it afterwards, so a session of
/// recordings left one poster each behind in the temporary directory.
@Suite("Ingest scratch files")
struct IngestScratchFileTests {
    private func makeStore() throws -> (HistoryStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-poster-\(UUID().uuidString)", isDirectory: true)
        return try (HistoryStore.open(root: root), root)
    }

    /// A capture on disk, plus a separate still to use as its thumbnail source.
    private func makeDraft(temporaryThumbnail: Bool) throws -> (HistoryIngest, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let capture = folder.appendingPathComponent("recording.mp4")
        try pngData().write(to: capture)
        let poster = folder.appendingPathComponent("poster.jpg")
        try pngData().write(to: poster)

        return (HistoryIngest(
            sourceURL: capture,
            kind: .video,
            pixelSize: PixelSize(width: 40, height: 30),
            originalFilename: "recording.mp4",
            thumbnailSourceURL: poster,
            thumbnailSourceIsTemporary: temporaryThumbnail
        ), poster)
    }

    private func pngData() throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: 40,
            height: 30,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw CocoaError(.featureUnsupported)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test("A poster rendered for the ingest is deleted once the library has its copy")
    func temporaryPosterIsRemoved() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (draft, poster) = try makeDraft(temporaryThumbnail: true)
        defer { try? FileManager.default.removeItem(at: poster.deletingLastPathComponent()) }

        let record = try await store.ingest(draft)

        #expect(!FileManager.default.fileExists(atPath: poster.path), "the scratch poster should be gone")
        #expect(
            FileManager.default.fileExists(atPath: store.thumbnailFileURL(for: record).path),
            "and the library's own copy should not be"
        )
    }

    @Test("A thumbnail source the caller owns is left alone")
    func permanentThumbnailSurvives() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (draft, poster) = try makeDraft(temporaryThumbnail: false)
        defer { try? FileManager.default.removeItem(at: poster.deletingLastPathComponent()) }

        _ = try await store.ingest(draft)
        #expect(FileManager.default.fileExists(atPath: poster.path))
    }
}
