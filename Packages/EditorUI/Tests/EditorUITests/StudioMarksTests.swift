import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// In and out marks, and exporting only what they enclose (docs/18 T-STU-11).
@Suite("Studio marks")
struct StudioMarksTests {
    @Test("The marked range fills a missing end with the edit's own", arguments: [
        (StudioMarks(inPoint: 2, outPoint: 5), 10.0, 2.0 ... 5.0),
        (StudioMarks(inPoint: 2), 10.0, 2.0 ... 10.0),
        (StudioMarks(outPoint: 4), 10.0, 0.0 ... 4.0),
        (StudioMarks(inPoint: -1, outPoint: 30), 10.0, 0.0 ... 10.0)
    ])
    func range(marks: StudioMarks, duration: TimeInterval, expected: ClosedRange<TimeInterval>) {
        #expect(marks.range(duration: duration) == expected)
    }

    @Test("No marks, or a stretch too short to export, is no range", arguments: [
        StudioMarks(),
        StudioMarks(inPoint: 3, outPoint: 3.05)
    ])
    func noRange(marks: StudioMarks) {
        #expect(marks.range(duration: 10) == nil)
    }

    @Test("A mark that would cross the other drops it")
    func crossing() {
        var marks = StudioMarks(inPoint: 2, outPoint: 5)
        marks.markIn(at: 6)
        #expect(marks.outPoint == nil)
        marks.markOut(at: 1)
        #expect(marks.inPoint == nil)
        #expect(marks.outPoint == 1)
    }

    @Test("Export renders the range only when asked to")
    func exportRange() {
        var marks = StudioMarks(inPoint: 2, outPoint: 5)
        #expect(marks.exportRange(duration: 10) == nil)
        marks.exportsRangeOnly = true
        #expect(marks.exportRange(duration: 10) == 2 ... 5)
    }

    @MainActor
    @Test("A range snapshot trims the edit to the marks")
    func snapshotTrims() async throws {
        let folder = StudioPlaybackFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try await StudioPlaybackFixtures.model(in: folder, seconds: 3)
        let snapshot = studio.exportSnapshot(range: 1 ... 2)
        #expect(abs(snapshot.edit.duration - 1) < 0.01)
        #expect(abs(studio.exportSnapshot().edit.duration - studio.edit.duration) < 0.01)
    }
}
