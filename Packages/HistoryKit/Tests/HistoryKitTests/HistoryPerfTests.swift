import Foundation
import Testing
@testable import HistoryKit

@Suite("History cold-open performance")
struct HistoryPerfTests {
    /// docs/03 §5: the browser cold-opens in under 400 ms at 1k items with paged thumbnails.
    @Test("Cold-open of the first page at 1k items stays under 400 ms")
    func coldOpenAtOneThousand() async throws {
        let root = try makeHistoryRoot()
        try seedLibrary(at: root, count: 1000)

        // A brand-new store, so SQLite and ImageIO have not warmed this process's view
        // of these files — that is the window-open path, not a second scroll.
        let store = try HistoryStore.open(root: root)
        let inserted = try await store.rebuild()
        #expect(inserted == 1000)

        let cold = try HistoryStore.open(root: root)
        let started = ContinuousClock.now
        let page = try await cold.loadPage(filter: .all, offset: 0, limit: 48)
        #expect(page.count == 48)
        for record in page {
            let thumb = cold.thumbnail(for: record, maxPixelSize: 256)
            #expect(thumb != nil, "paged thumbnail missing for \(record.originalFilename)")
        }
        let elapsed = started.duration(to: .now)
        let milliseconds = elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000

        #expect(
            elapsed < .milliseconds(400),
            "cold-open took \(milliseconds) ms at 1k items (budget 400 ms, docs/03 §5)"
        )
    }

    /// docs/03 §5 P3: search is a field you type into, so it has to answer at typing
    /// speed. Same 400 ms budget as the cold open, at the same 1k items.
    @Test("Search across 1k indexed items answers within the cold-open budget")
    func searchAtOneThousand() async throws {
        let root = try makeHistoryRoot()
        try seedLibrary(at: root, count: 1000)

        let store = try HistoryStore.open(root: root)
        #expect(try await store.rebuild() == 1000)

        // Index every record, with one needle hidden among the haystack.
        let records = try await store.loadPage(filter: .all, offset: 0, limit: 1000)
        for (index, record) in records.enumerated() {
            try await store.index(
                id: record.id,
                text: index == 500 ? "quarterly revenue chart" : "unremarkable window contents \(index)",
                applicationName: "Seed"
            )
        }

        let cold = try HistoryStore.open(root: root)
        let started = ContinuousClock.now
        let hits = try await cold.search("quarterly")
        let elapsed = started.duration(to: .now)
        let milliseconds = elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000

        #expect(hits.count == 1)
        #expect(
            elapsed < .milliseconds(400),
            "search took \(milliseconds) ms at 1k items (budget 400 ms, docs/03 §5)"
        )
    }
}

/// Writes 1k unique captures + sidecars + thumbnails without going through ingest, so the
/// measured interval is the open, not the seed.
private func seedLibrary(at root: URL, count: Int) throws {
    let layout = HistoryLayout(root: root)
    try layout.prepare()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    for index in 0 ..< count {
        let source = try writeTestImage(seed: index)
        let hash = try HistoryContentAddress.hash(of: source)
        let capture = layout.captureURL(hash: hash, fileExtension: "png")
        try HistoryContentAddress.install(from: source, to: capture)
        let thumb = layout.thumbnailURL(hash: hash)
        try HistoryThumbnailWriter.write(from: capture, to: thumb)
        let record = try HistoryRecord(
            contentHash: hash,
            relativePath: layout.relativePath(for: capture),
            thumbnailRelativePath: layout.relativePath(for: thumb),
            kind: .image,
            width: 32,
            height: 16,
            applicationName: "Seed",
            capturedAt: now.addingTimeInterval(TimeInterval(index)),
            lastAccessedAt: now.addingTimeInterval(TimeInterval(index)),
            byteSize: Int64((capture.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            originalFilename: "seed-\(index).png"
        )
        try HistorySidecar.write(record, to: layout.sidecarURL(id: record.id))
    }
}
