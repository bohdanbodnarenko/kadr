import Foundation
import Shared
import Testing
@testable import HistoryKit

@Suite("History store")
struct HistoryStoreTests {
    @Test("Ingest copies the file, writes a sidecar and a thumbnail, and indexes the row")
    func ingestIndexes() async throws {
        let root = try makeHistoryRoot()
        let store = try HistoryStore.open(root: root)
        let record = try await store.ingest(ingestDraft(seed: 1))

        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: record).path))
        #expect(FileManager.default.fileExists(atPath: store.thumbnailFileURL(for: record).path))
        #expect(FileManager.default.fileExists(atPath: store.layout.sidecarURL(id: record.id).path))
        #expect(record.applicationName == "Tester")
        #expect(record.pixelSize == PixelSize(width: 32, height: 16))
        #expect(try await store.recent(limit: 8).count == 1)
    }

    @Test("Newest captures come first")
    func newestFirst() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        try await store.ingest(ingestDraft(seed: 1, capturedAt: older))
        try await store.ingest(ingestDraft(seed: 2, capturedAt: newer))

        let recent = try await store.recent(limit: 8)
        #expect(recent.map(\.originalFilename) == ["capture-2.png", "capture-1.png"])
    }

    @Test("Deleting from history removes the files (docs/03 §5)")
    func deleteRemovesFiles() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let record = try await store.ingest(ingestDraft(seed: 3))
        let file = store.fileURL(for: record)
        let thumb = store.thumbnailFileURL(for: record)
        let sidecar = store.layout.sidecarURL(id: record.id)

        let report = try await store.delete(ids: [record.id])

        #expect(report.deletedCount == 1)
        #expect(report.freedBytes == record.byteSize)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(try await store.recent(limit: 8).isEmpty)
    }

    @Test("Two records that share bytes keep the file until the last one is deleted")
    func sharedContentSurvivesUntilLastDelete() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let source = try writeTestImage(seed: 9)
        let first = try await store.ingest(HistoryIngest(
            sourceURL: source,
            kind: .image,
            pixelSize: PixelSize(width: 32, height: 16),
            capturedAt: Date(),
            originalFilename: "one.png"
        ))
        let second = try await store.ingest(HistoryIngest(
            sourceURL: source,
            kind: .image,
            pixelSize: PixelSize(width: 32, height: 16),
            capturedAt: Date().addingTimeInterval(1),
            originalFilename: "two.png"
        ))
        #expect(first.contentHash == second.contentHash)

        _ = try await store.delete(ids: [first.id])
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: second).path))

        _ = try await store.delete(ids: [second.id])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: second).path))
    }

    @Test("Type and date filters return the matching page")
    func filters() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.ingest(ingestDraft(seed: 1, capturedAt: now, kind: .image))
        try await store.ingest(ingestDraft(seed: 2, capturedAt: now, kind: .video))
        try await store.ingest(ingestDraft(
            seed: 3,
            capturedAt: now.addingTimeInterval(-86400 * 10),
            kind: .image
        ))

        let videos = try await store.loadPage(filter: HistoryFilter(kind: .video), offset: 0, limit: 10)
        #expect(videos.count == 1)
        #expect(videos.first?.kind == .video)

        let recentImages = try await store.loadPage(
            filter: HistoryFilter(kind: .image, capturedAfter: now.addingTimeInterval(-86400)),
            offset: 0,
            limit: 10
        )
        #expect(recentImages.count == 1)
        #expect(recentImages.first?.originalFilename == "capture-1.png")
    }

    @Test("A missing source is refused rather than inserting a blank row")
    func missingSource() async throws {
        let store = try HistoryStore.open(root: makeHistoryRoot())
        let draft = HistoryIngest(
            sourceURL: URL(fileURLWithPath: "/nope/kadr-missing.png"),
            kind: .image,
            pixelSize: PixelSize(width: 1, height: 1),
            originalFilename: "missing.png"
        )
        await #expect(throws: HistoryError.self) {
            try await store.ingest(draft)
        }
        #expect(try await store.storageUsage().itemCount == 0)
    }
}
