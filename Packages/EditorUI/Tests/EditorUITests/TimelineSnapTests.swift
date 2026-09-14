import Testing
@testable import EditorUI

@Suite("Timeline snap (docs/14 UX-32)")
struct TimelineSnapTests {
    @Test("A time within 8 points of a candidate snaps to it")
    func snapsInsideWindow() {
        let snapped = TimelineSnap.snap(1.02, candidates: [0, 1, 5], scale: 100)
        #expect(snapped == 1)
    }

    @Test("A time outside the window is left alone")
    func ignoresDistantTimes() {
        let snapped = TimelineSnap.snap(1.5, candidates: [0, 1, 5], scale: 100)
        #expect(snapped == 1.5)
    }
}
