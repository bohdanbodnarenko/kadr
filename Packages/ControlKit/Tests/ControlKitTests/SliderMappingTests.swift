import Foundation
import Testing
@testable import ControlKit

@Suite("Slider mapping")
struct SliderMappingTests {
    @Test("Progress is the value's place in the range")
    func progress() {
        #expect(SliderMapping.progress(of: 0.5, in: 0 ... 1) == 0.5)
        #expect(SliderMapping.progress(of: 0, in: -1 ... 1) == 0.5)
        #expect(SliderMapping.progress(of: -1, in: -1 ... 1) == 0)
        #expect(SliderMapping.progress(of: 2, in: 0 ... 1) == 1)
    }

    @Test("Zero is marked only when the range actually crosses it")
    func zeroProgress() {
        #expect(SliderMapping.zeroProgress(in: 0 ... 1) == nil)
        #expect(SliderMapping.zeroProgress(in: -180 ... 180) == 0.5)
        #expect(SliderMapping.zeroProgress(in: -0.5 ... 0.5) == 0.5)
    }

    @Test("A click on the track is the value at that position")
    func absoluteScrub() {
        #expect(SliderMapping.value(at: 0, width: 100, range: 0 ... 1) == 0)
        #expect(SliderMapping.value(at: 50, width: 100, range: 0 ... 1) == 0.5)
        #expect(SliderMapping.value(at: 100, width: 100, range: 0 ... 1) == 1)
        #expect(SliderMapping.value(at: -10, width: 100, range: 0 ... 1) == 0)
        #expect(SliderMapping.value(at: 200, width: 100, range: 0 ... 1) == 1)
    }

    @Test("A signed range snaps a few points around the middle onto zero")
    func zeroDetent() {
        let range: ClosedRange<Double> = -1 ... 1
        #expect(SliderMapping.value(at: 50, width: 100, range: range) == 0)
        #expect(SliderMapping.value(at: 47, width: 100, range: range) == 0)
        #expect(SliderMapping.value(at: 53, width: 100, range: range) == 0)
        let justLeft = SliderMapping.value(at: 46, width: 100, range: range)
        #expect(justLeft < 0)
        #expect(justLeft > range.lowerBound)
        let justRight = SliderMapping.value(at: 54, width: 100, range: range)
        #expect(justRight > 0)
        #expect(justRight < range.upperBound)
    }
}

@Suite("Slider step snapping")
struct SliderSnappingTests {
    @Test("A dragged value lands on the step grid", arguments: [
        (0.31, 0.3), (0.37, 0.35), (0.5, 0.5), (0.999, 1.0)
    ])
    func snapsToGrid(value: Double, expected: Double) {
        #expect(abs(SliderMapping.snapped(value, step: 0.05, in: 0 ... 1) - expected) < 0.0001)
    }

    @Test("A range that does not start at zero counts its steps from its lower bound")
    func stepsCountFromTheLowerBound() {
        #expect(SliderMapping.snapped(155, step: 20, in: 140 ... 420) == 160)
        #expect(SliderMapping.snapped(149, step: 20, in: 140 ... 420) == 140)
    }

    @Test("A signed range keeps zero as a stop, so the detent is reachable")
    func signedRangeKeepsZero() {
        #expect(SliderMapping.snapped(0, step: 7, in: -180 ... 180) == 0)
        #expect(SliderMapping.snapped(3, step: 7, in: -180 ... 180) == 0)
        #expect(SliderMapping.snapped(-10, step: 7, in: -180 ... 180) == -7)
        #expect(SliderMapping.snapped(-11, step: 7, in: -180 ... 180) == -14)
    }

    @Test("Snapping never leaves the range")
    func staysInRange() {
        #expect(SliderMapping.snapped(419, step: 20, in: 140 ... 420) == 420)
        #expect(SliderMapping.snapped(1000, step: 20, in: 140 ... 420) == 420)
        #expect(SliderMapping.snapped(-5, step: 20, in: 140 ... 420) == 140)
    }

    @Test("No step means no snapping, only clamping", arguments: [nil, 0.0, -1.0, Double.nan])
    func noStep(step: Double?) {
        #expect(SliderMapping.snapped(0.123, step: step, in: 0 ... 1) == 0.123)
        #expect(SliderMapping.snapped(2, step: step, in: 0 ... 1) == 1)
    }
}
