import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

@Suite("Studio timeline playhead")
struct StudioTimelinePlayheadTests {
    @Test("A point on the timeline maps to the time under it")
    func timeAtX() {
        #expect(StudioTimelinePlayhead.time(atX: 50, scale: 10, duration: 20) == 5)
        #expect(StudioTimelinePlayhead.time(atX: -4, scale: 10, duration: 20) == 0)
        #expect(StudioTimelinePlayhead.time(atX: 400, scale: 10, duration: 20) == 20)
        #expect(StudioTimelinePlayhead.time(atX: 10, scale: 0, duration: 20) == 0)
    }

    @Test("The pin's tail points at the frame, not beside it")
    func crownHasATail() {
        let path = PlayheadCrownShape().path(in: CGRect(x: 0, y: 0, width: 11, height: 13))
        #expect(path.contains(CGPoint(x: 5.5, y: 12.4)), "the tail should fill the bottom center")
        #expect(!path.contains(CGPoint(x: 0.4, y: 12.4)), "the tail should not fill the bottom corners")
        #expect(path.contains(CGPoint(x: 5.5, y: 2)), "the flag body is missing")
    }
}

/// docs/18 STU-3: a zoomed timeline scrolls only when the needle leaves the view.
@Suite("Playhead following")
struct PlayheadFollowingTests {
    @Test("Only a needle outside the visible range pages the view", arguments: [
        (CGFloat(-1), true),
        (0, false),
        (400, false),
        (791, false),
        (793, true),
        (1200, true)
    ])
    func outOfView(needleX: CGFloat, follows: Bool) {
        #expect(PlayheadFollower.needleIsOutOfView(needleX: needleX, viewportWidth: 800) == follows)
    }
}
