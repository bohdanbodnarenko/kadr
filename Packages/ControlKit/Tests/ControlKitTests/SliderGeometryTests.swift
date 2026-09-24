import Foundation
import Testing
@testable import ControlKit

/// Where the fill and the handle sit (docs/09 U1.5). The look is a gap between two things,
/// so the gap is what is pinned down here.
@Suite("Slider geometry")
struct SliderGeometryTests {
    private let geometry = SliderGeometry(width: 200, height: 32)

    @Test("At zero the fill is a circle as wide as it is tall")
    func collapsedFillIsACircle() {
        #expect(geometry.fillWidth(progress: 0) == geometry.fillHeight)
    }

    @Test("The fill never reaches the handle: there is always the gap between them")
    func gapIsConstant() {
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let fillEnd = geometry.inset + geometry.fillWidth(progress: progress)
            let handleLeading = geometry.handleCenter(progress: progress) - geometry.handleWidth / 2
            #expect(abs((handleLeading - fillEnd) - geometry.gap) < 0.0001, "at \(progress)")
        }
    }

    @Test("The handle stays inside the track at both ends")
    func handleStaysInside() {
        let low = geometry.handleCenter(progress: 0) - geometry.handleWidth / 2
        let high = geometry.handleCenter(progress: 1) + geometry.handleWidth / 2
        #expect(low > 0)
        #expect(high <= geometry.width - geometry.inset)
    }

    @Test("Progress outside 0…1 is clamped rather than drawn off the track")
    func clamps() {
        #expect(geometry.handleCenter(progress: -1) == geometry.handleCenter(progress: 0))
        #expect(geometry.handleCenter(progress: 2) == geometry.handleCenter(progress: 1))
    }

    @Test("The handle moves in step with the value")
    func handleIsLinear() {
        let quarter = geometry.handleCenter(progress: 0.25)
        let half = geometry.handleCenter(progress: 0.5)
        let start = geometry.handleCenter(progress: 0)
        #expect(abs((half - start) - 2 * (quarter - start)) < 0.0001)
    }

    @Test("A pointer at the handle's own position reads back as the same progress")
    func pointerMapsBackToProgress() {
        for progress in [0.0, 0.3, 0.5, 0.9, 1.0] {
            let x = geometry.handleCenter(progress: progress)
            let value = SliderMapping.value(
                at: geometry.travelledX(for: x),
                width: geometry.travelLength,
                range: 0 ... 1
            )
            #expect(abs(value - progress) < 0.0001, "at \(progress)")
        }
    }

    @Test("A pointer past either end pins the value to that end")
    func pointerPastTheEnds() {
        func value(atX x: Double) -> Double {
            SliderMapping.value(at: geometry.travelledX(for: x), width: geometry.travelLength, range: 0 ... 1)
        }
        #expect(value(atX: -50) == 0)
        #expect(value(atX: 500) == 1)
    }

    @Test("A track too narrow for the handle to travel degrades to the start, not a crash", arguments: [0.0, 10, 40])
    func narrowTrack(width: Double) {
        let narrow = SliderGeometry(width: width, height: 32)
        #expect(narrow.travelLength == 0)
        #expect(narrow.fillWidth(progress: 1).isFinite)
        #expect(SliderMapping.value(at: 5, width: narrow.travelLength, range: 0 ... 1) == 0)
    }

    @Test("A smaller control draws a thinner border", arguments: [(20.0, 2.0), (24, 2), (32, 3), (40, 3)])
    func insetFollowsHeight(height: Double, inset: Double) {
        #expect(SliderGeometry(width: 200, height: height).inset == inset)
    }
}
