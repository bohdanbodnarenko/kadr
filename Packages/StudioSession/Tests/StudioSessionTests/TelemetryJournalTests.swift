import CoreGraphics
import Foundation
import Testing
@testable import StudioSession

@Suite("Telemetry journal")
struct TelemetryJournalTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-journal-\(UUID().uuidString).jsonl")
    }

    @Test("Chunks round-trip in order")
    func roundTrip() throws {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = TelemetryJournal(url: url)

        try journal.append(TelemetryJournal.Chunk(
            pointer: [PointerSample(time: 0.1, position: CGPoint(x: 1, y: 2))]
        ))
        try journal.append(TelemetryJournal.Chunk(
            pointer: [PointerSample(time: 60.2, position: CGPoint(x: 3, y: 4))],
            clicks: [ClickEvent(time: 60.3, position: CGPoint(x: 3, y: 4))]
        ))

        let loaded = journal.load()
        #expect(loaded.pointer.map(\.time) == [0.1, 60.2])
        #expect(loaded.clicks.count == 1)
    }

    @Test("An empty chunk is not written")
    func skipsEmpty() throws {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url) }
        try TelemetryJournal(url: url).append(TelemetryJournal.Chunk())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A missing file loads as empty rather than throwing")
    func missingFile() {
        let loaded = TelemetryJournal(url: URL(fileURLWithPath: "/nope.jsonl")).load()
        #expect(loaded.pointer.isEmpty)
        #expect(loaded.clicks.isEmpty)
        #expect(loaded.keystrokes.isEmpty)
    }
}
