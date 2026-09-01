import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

@Suite("Studio timeline zoom")
struct StudioTimelineZoomTests {
    @Test("Zoom never drops below fit or past the cap")
    func clamp() {
        #expect(StudioTimelineZoom.clamp(0.2) == 1)
        #expect(StudioTimelineZoom.clamp(1) == 1)
        #expect(StudioTimelineZoom.clamp(12) == 12)
        #expect(StudioTimelineZoom.clamp(99) == StudioTimelineZoom.maximum)
    }

    @Test("A tiny scroll tick does not rescale")
    func tinyScrollIsIdentity() {
        #expect(StudioTimelineZoom.factor(fromScrollDelta: 0, precise: true) == 1)
        #expect(StudioTimelineZoom.factor(fromScrollDelta: 0.0004, precise: true) == 1)
    }

    @Test("⌘-scroll doubles the scale after the documented distance")
    func scrollDoublesAtTheDocumentedDistance() {
        let factor = StudioTimelineZoom.factor(
            fromScrollDelta: StudioTimelineZoom.scrollPointsPerDoubling,
            precise: true
        )
        #expect(abs(factor - 2) < 0.0001)
    }

    @Test("The pointer's place in the viewport is a unit point")
    func viewportFraction() {
        #expect(StudioTimelineZoom.viewportFraction(pointerX: 50, viewportWidth: 200) == 0.25)
        #expect(StudioTimelineZoom.viewportFraction(pointerX: -10, viewportWidth: 200) == 0)
        #expect(StudioTimelineZoom.viewportFraction(pointerX: 400, viewportWidth: 200) == 1)
        #expect(StudioTimelineZoom.viewportFraction(pointerX: 10, viewportWidth: 0) == 0.5)
    }

    @Test("Zooming keeps the anchored time under the pointer")
    func scrollOriginPinsTime() {
        // After a 2× stretch, t=5 sits at x=100. The pointer is at viewport x=80,
        // so the content has to start 20 points to the left of the viewport.
        let origin = StudioTimelineZoom.scrollOrigin(
            keeping: 5,
            atPointerX: 80,
            scale: 20,
            contentWidth: 400,
            viewportWidth: 200
        )
        #expect(origin == 20)
    }

    @Test("A pin past the start of the recording clamps rather than scrolling negative")
    func originDoesNotGoNegative() {
        let origin = StudioTimelineZoom.scrollOrigin(
            keeping: 0.5,
            atPointerX: 80,
            scale: 20,
            contentWidth: 400,
            viewportWidth: 200
        )
        #expect(origin == 0)
    }

    @Test("A pin past the end of the recording stops at the last viewport")
    func originDoesNotPastTheEnd() {
        let origin = StudioTimelineZoom.scrollOrigin(
            keeping: 19,
            atPointerX: 20,
            scale: 20,
            contentWidth: 400,
            viewportWidth: 200
        )
        #expect(origin == 200)
    }
}
