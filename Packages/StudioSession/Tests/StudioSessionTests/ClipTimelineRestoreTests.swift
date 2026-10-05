import Foundation
import Testing
@testable import StudioSession

/// Restoring a cut stretch of the recording (docs/18 STU-10).
@Suite("Restoring source ranges")
struct ClipTimelineRestoreTests {
    private func ranges(_ timeline: ClipTimeline) -> [ClosedRange<TimeInterval>] {
        timeline.clips.map(\.sourceRange)
    }

    @Test("Cutting a word and restoring it gives back the timeline", arguments: [
        (2.0, 2.5),
        (0.0, 1.0),
        (9.0, 10.0)
    ])
    func roundTrip(start: TimeInterval, end: TimeInterval) {
        let whole = ClipTimeline.whole(duration: 10)
        let restored = whole.removingSourceRange(from: start, to: end).restoringSourceRange(from: start, to: end)
        #expect(ranges(restored) == ranges(whole))
    }

    @Test("Only the uncovered part comes back")
    func partialOverlap() {
        let cut = ClipTimeline.whole(duration: 10).removingSourceRange(from: 2, to: 4)
        let restored = cut.restoringSourceRange(from: 3, to: 5)
        #expect(ranges(restored) == [0 ... 2, 3 ... 10])
    }

    @Test("Restoring what is already there changes nothing")
    func nothingToRestore() {
        let whole = ClipTimeline.whole(duration: 10)
        #expect(whole.restoringSourceRange(from: 2, to: 3) == whole)
    }

    @Test("A sped-up neighbour is not merged with the restored piece")
    func keepsSpeed() {
        var cut = ClipTimeline.whole(duration: 10).removingSourceRange(from: 4, to: 5)
        cut.clips[0].speed = 2
        let restored = cut.restoringSourceRange(from: 4, to: 5)
        #expect(ranges(restored) == [0 ... 4, 4 ... 10])
        #expect(restored.clips.map(\.speed) == [2, 1])
    }
}
