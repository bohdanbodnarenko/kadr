import Foundation
import Shared
import Testing
@testable import HistoryKit

/// docs/18 OUT-4: an edited capture keeps its History row.
@Suite("History content replacement", .serialized)
struct HistoryReplaceTests {
    @Test("Replacing keeps the id, date and app name, and frees the old bytes")
    func keepsIdentity() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore.open(root: root)
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let original = try await store.ingest(ingestDraft(seed: 1, capturedAt: capturedAt))
        try await store.index(id: original.id, text: "old text", applicationName: "Tester")
        let edited = try writeTestImage(seed: 2)

        let replaced = try #require(try await store.replaceContent(
            previousHash: original.contentHash,
            with: edited,
            pixelSize: PixelSize(width: 64, height: 32)
        ))

        #expect(replaced.id == original.id)
        #expect(replaced.capturedAt == capturedAt)
        #expect(replaced.applicationName == "Tester")
        #expect(replaced.contentHash != original.contentHash)
        #expect(replaced.width == 64)
        #expect(try await store.storageUsage().itemCount == 1)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: original).path))
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: replaced).path))
        #expect(try await store.unindexedCount() == 1, "the new pixels are read again")
    }

    @Test("A hash History does not hold returns nil, so the caller ingests")
    func unknownHash() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore.open(root: root)
        let replaced = try await store.replaceContent(
            previousHash: "nothing-here",
            with: writeTestImage(seed: 3),
            pixelSize: PixelSize(width: 1, height: 1)
        )
        #expect(replaced == nil)
    }
}
