import Foundation
import Testing
@testable import StudioSession

/// Exporting only the marked range (docs/18 T-STU-11).
@Suite("Clip timeline range")
struct ClipTimelineRangeTests {
    /// 0–4 s of source at 1×, then 10–14 s at 2× (2 s edited): 6 s edited in all.
    private let timeline = ClipTimeline(clips: [
        Clip(sourceStart: 0, sourceDuration: 4),
        Clip(sourceStart: 10, sourceDuration: 4, speed: 2)
    ])

    @Test("A range keeps the overlapping source, at each clip's speed", arguments: [
        (1.0 ... 3.0, [(1.0, 2.0, 1.0)]),
        (3.0 ... 5.0, [(3.0, 1.0, 1.0), (10.0, 2.0, 2.0)]),
        (4.5 ... 6.0, [(11.0, 3.0, 2.0)]),
        (0.0 ... 6.0, [(0.0, 4.0, 1.0), (10.0, 4.0, 2.0)])
    ])
    func keepsRange(range: ClosedRange<TimeInterval>, expected: [(Double, Double, Double)]) {
        let kept = timeline.keepingEdited(range)
        #expect(kept.clips.count == expected.count)
        for (clip, want) in zip(kept.clips, expected) {
            #expect(abs(clip.sourceStart - want.0) < 1e-9)
            #expect(abs(clip.sourceDuration - want.1) < 1e-9)
            #expect(clip.speed == want.2)
        }
        #expect(abs(kept.editedDuration - (range.upperBound - range.lowerBound)) < 1e-9)
    }

    @Test("A range past the end keeps nothing")
    func pastEnd() {
        #expect(timeline.keepingEdited(7 ... 9).isEmpty)
    }
}
