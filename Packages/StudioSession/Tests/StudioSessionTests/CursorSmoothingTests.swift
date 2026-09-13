import Foundation
import Testing
@testable import StudioSession

@Suite("Cursor smoothing")
struct CursorSmoothingTests {
    @Test("Smooth is the default look, and Off is stiffer than Natural")
    func stiffnessOrder() {
        #expect(CursorSmoothing.smooth.stiffness == 12)
        #expect(CursorSmoothing.natural.stiffness > CursorSmoothing.smooth.stiffness)
        #expect(CursorSmoothing.off.stiffness > CursorSmoothing.natural.stiffness)
    }

    @Test("Every case has a title of its own")
    func titlesAreDistinct() {
        let titles = CursorSmoothing.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        let ripples = ClickRippleStyle.allCases.map(\.title)
        #expect(Set(ripples).count == ripples.count)
        let zooms = ZoomAnimationStyle.allCases.map(\.title)
        #expect(Set(zooms).count == zooms.count)
    }

    @Test("Dynamic zoom is snappier than Smooth, and neither is the pointer look")
    func zoomStyleIsItsOwnSpring() {
        #expect(ZoomAnimationStyle.smooth.stiffness == CursorSmoothing.smooth.stiffness)
        #expect(ZoomAnimationStyle.dynamic.stiffness > ZoomAnimationStyle.smooth.stiffness)
        #expect(ZoomAnimationStyle.dynamic.stiffness != CursorSmoothing.natural.stiffness)
        #expect(ZoomAnimationStyle.dynamic.stiffness != CursorSmoothing.off.stiffness)
    }
}
