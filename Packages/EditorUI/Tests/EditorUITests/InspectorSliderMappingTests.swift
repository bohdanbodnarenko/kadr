import Foundation
import Testing
@testable import EditorUI

@Suite("Inspector slider mapping")
struct InspectorSliderMappingTests {
    @Test("Progress is the value's place in the range")
    func progress() {
        #expect(InspectorSliderMapping.progress(of: 0.5, in: 0 ... 1) == 0.5)
        #expect(InspectorSliderMapping.progress(of: 0, in: -1 ... 1) == 0.5)
        #expect(InspectorSliderMapping.progress(of: -1, in: -1 ... 1) == 0)
        #expect(InspectorSliderMapping.progress(of: 2, in: 0 ... 1) == 1)
    }

    @Test("Zero is marked only when the range actually crosses it")
    func zeroProgress() {
        #expect(InspectorSliderMapping.zeroProgress(in: 0 ... 1) == nil)
        #expect(InspectorSliderMapping.zeroProgress(in: -180 ... 180) == 0.5)
        #expect(InspectorSliderMapping.zeroProgress(in: -0.5 ... 0.5) == 0.5)
    }

    @Test("A click on the track is the value at that position")
    func absoluteScrub() {
        #expect(InspectorSliderMapping.value(at: 0, width: 100, range: 0 ... 1) == 0)
        #expect(InspectorSliderMapping.value(at: 50, width: 100, range: 0 ... 1) == 0.5)
        #expect(InspectorSliderMapping.value(at: 100, width: 100, range: 0 ... 1) == 1)
        #expect(InspectorSliderMapping.value(at: -10, width: 100, range: 0 ... 1) == 0)
        #expect(InspectorSliderMapping.value(at: 200, width: 100, range: 0 ... 1) == 1)
    }

    @Test("A signed range snaps a few points around the middle onto zero")
    func zeroDetent() {
        let range: ClosedRange<Double> = -1 ... 1
        #expect(InspectorSliderMapping.value(at: 50, width: 100, range: range) == 0)
        #expect(InspectorSliderMapping.value(at: 47, width: 100, range: range) == 0)
        #expect(InspectorSliderMapping.value(at: 53, width: 100, range: range) == 0)
        let justLeft = InspectorSliderMapping.value(at: 46, width: 100, range: range)
        #expect(justLeft < 0)
        #expect(justLeft > range.lowerBound)
        let justRight = InspectorSliderMapping.value(at: 54, width: 100, range: range)
        #expect(justRight > 0)
        #expect(justRight < range.upperBound)
    }
}
