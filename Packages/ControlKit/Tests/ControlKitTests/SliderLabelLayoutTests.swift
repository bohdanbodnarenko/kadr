import Foundation
import Testing
@testable import ControlKit

/// The labels jump to the opposite end of the track rather than be run over by the handle
/// (docs/09 U1.5).
@Suite("Slider label layout")
struct SliderLabelLayoutTests {
    private typealias Placement = SliderLabelLayout.Placement

    private func layout(
        width: Double = 280,
        title: Double = 50,
        value: Double = 30
    ) -> SliderLabelLayout {
        SliderLabelLayout(
            geometry: SliderGeometry(width: width, height: 32),
            textInset: 12,
            titleWidth: title,
            valueWidth: value,
            valueBoxWidth: 60,
            valueReserve: 44
        )
    }

    /// Every progress from one end to the other, in `steps` increments, in both directions —
    /// because where a label goes depends on where it was.
    private func sweep(_ layout: SliderLabelLayout, steps: Int = 400) -> [(Double, Placement)] {
        var placement = Placement()
        var visited: [(Double, Placement)] = []
        let forward = (0 ... steps).map { Double($0) / Double(steps) }
        for progress in forward + forward.reversed() {
            placement = layout.resolved(from: placement, progress: progress)
            visited.append((progress, placement))
        }
        return visited
    }

    @Test("On a track with room for both ends, the handle never touches a label", arguments: [
        (280.0, 50.0, 30.0), (280, 80, 44), (400, 30, 24), (240, 50, 30)
    ])
    func handleNeverTouchesALabel(width: Double, title: Double, value: Double) {
        let layout = layout(width: width, title: title, value: value)
        let geometry = layout.geometry
        for (progress, placement) in sweep(layout) {
            let center = geometry.handleCenter(progress: progress)
            let left = center - geometry.handleWidth / 2
            let right = center + geometry.handleWidth / 2
            for span in layout.occupiedSpans(placement) {
                let clear = span.lowerBound >= right + layout.clearance - 0.001
                    || span.upperBound <= left - layout.clearance + 0.001
                #expect(clear, "handle at \(progress) touches \(span) (\(width)pt wide)")
            }
        }
    }

    @Test("A track too short for both ends still lays out finitely, whatever the handle does")
    func shortTrackStaysSane() {
        let layout = layout(width: 150, title: 70, value: 40)
        for (_, placement) in sweep(layout) {
            for span in layout.occupiedSpans(placement) {
                #expect(span.lowerBound.isFinite && span.upperBound.isFinite)
                #expect(span.lowerBound >= 0)
            }
        }
    }

    @Test("Nothing jumps while the handle is in the middle, clear of both ends")
    func restingLayout() {
        let layout = layout()
        let placement = layout.resolved(from: .init(), progress: 0.5)
        #expect(placement == Placement())
        #expect(layout.titleX(placement) == 12)
        #expect(layout.valueRight(placement) == 280 - 12)
    }

    @Test("The title jumps to the trailing end, before the number, while the handle is at its home")
    func titleJumpsToTheTrailingEnd() {
        let layout = layout()
        let placement = layout.resolved(from: .init(), progress: 0)
        #expect(placement.titleAtTrailing)
        #expect(!placement.valueAtLeading)
        // Right-aligned to where the number's reserved room begins.
        #expect(layout.titleX(placement) + layout.titleShownWidth == 280 - 12 - 44 - layout.labelGap)
    }

    @Test("The number jumps to the leading end, after the title, once the handle reaches it")
    func valueJumpsToTheLeadingEnd() {
        let layout = layout()
        let placement = layout.resolved(from: .init(), progress: 1)
        #expect(placement.valueAtLeading)
        #expect(!placement.titleAtTrailing)
        #expect(layout.valueRight(placement) == 12 + layout.titleShownWidth + layout.labelGap + 30)
    }

    @Test("A number that jumps with no title in the way starts at the leading inset")
    func valueJumpsWithoutATitle() {
        let layout = layout(title: 0)
        let placement = layout.resolved(from: .init(), progress: 1)
        #expect(placement.valueAtLeading)
        #expect(layout.valueRight(placement) == 12 + 30)
    }

    /// Without this a handle held still on the boundary — or nudged a pixel either way by a
    /// shaky hand — would make the label leap back and forth across the track.
    @Test("A label that has jumped does not come straight back at a small step")
    func hysteresis() {
        let layout = layout()
        let length = layout.geometry.travelLength
        var placement = Placement()
        var progress = 0.0
        while progress <= 1 {
            placement = layout.resolved(from: placement, progress: progress)
            if !placement.titleAtTrailing, progress > 0 {
                break
            }
            progress += 0.001
        }
        #expect(!placement.titleAtTrailing)
        let stepBack = progress - 5 / length
        #expect(!layout.resolved(from: placement, progress: stepBack).titleAtTrailing)
    }

    @Test("The number's jump has the same margin, in the other direction")
    func valueHysteresis() {
        let layout = layout()
        let length = layout.geometry.travelLength
        var placement = Placement()
        var progress = 1.0
        var sawJump = false
        while progress >= 0 {
            placement = layout.resolved(from: placement, progress: progress)
            if placement.valueAtLeading {
                sawJump = true
            }
            if sawJump, !placement.valueAtLeading {
                break
            }
            progress -= 0.001
        }
        #expect(sawJump && !placement.valueAtLeading)
        let stepForward = progress + 5 / length
        #expect(!layout.resolved(from: placement, progress: stepForward).valueAtLeading)
    }

    @Test("Without a title nothing jumps on its account")
    func noTitle() {
        let layout = layout(title: 0)
        for (_, placement) in sweep(layout) {
            #expect(!placement.titleAtTrailing)
        }
        #expect(layout.titleShownWidth == 0)
        #expect(layout.occupiedSpans(.init()).count == 1)
    }

    @Test("A title too long for its room is truncated, never run into the number")
    func longTitleIsTruncated() {
        let layout = layout(width: 200, title: 400)
        #expect(layout.titleShownWidth < 200 - 60)
        #expect(layout.titleShownWidth > 0)
    }

    @Test("A press on the number is found where the number is, not where it rests")
    func hitTestFollowsTheValue() {
        let layout = layout()
        let resting = Placement()
        #expect(layout.isOnValue(x: 260, placement: resting))
        #expect(!layout.isOnValue(x: 150, placement: resting))
        let jumped = layout.resolved(from: .init(), progress: 1)
        let right = layout.valueRight(jumped)
        #expect(layout.isOnValue(x: right - 10, placement: jumped))
        #expect(!layout.isOnValue(x: 268, placement: jumped))
    }
}

@Suite("Slider ticks")
struct SliderTicksTests {
    private let geometry = SliderGeometry(width: 280, height: 32)

    @Test("An unsigned range is marked evenly, end to end")
    func evenTicks() {
        let ticks = SliderTicks.ticks(in: geometry, zeroProgress: nil)
        #expect(ticks.count >= 3)
        #expect(ticks.first?.x == geometry.handleCenter(progress: 0))
        #expect(ticks.last?.x == geometry.handleCenter(progress: 1))
        #expect(ticks.allSatisfy { !$0.isZero })
        let gaps = zip(ticks, ticks.dropFirst()).map { $1.x - $0.x }
        let first = gaps[0]
        #expect(gaps.allSatisfy { abs($0 - first) < 0.0001 })
    }

    @Test("A signed range grows its grid from zero, and zero is one of the ticks")
    func zeroAnchoredTicks() {
        let ticks = SliderTicks.ticks(in: geometry, zeroProgress: 0.5)
        let zero = ticks.filter(\.isZero)
        #expect(zero.count == 1)
        #expect(zero[0].x == geometry.handleCenter(progress: 0.5))
        let travel = geometry.handleTravel
        #expect(ticks.allSatisfy { $0.x >= travel.lowerBound - 0.5 && $0.x <= travel.upperBound + 0.5 })
        for tick in ticks where !tick.isZero {
            let steps = abs(tick.x - zero[0].x) / SliderTicks.spacing
            #expect(abs(steps - steps.rounded()) < 0.0001, "tick at \(tick.x) is off the grid")
        }
    }

    @Test("Ticks are in order, so they can be laid out left to right")
    func ordered() {
        let ticks = SliderTicks.ticks(in: geometry, zeroProgress: 0.3)
        #expect(ticks.map(\.x) == ticks.map(\.x).sorted())
    }

    @Test("A track too narrow to mark has no ticks", arguments: [0.0, 40, 60])
    func narrow(width: Double) {
        #expect(SliderTicks.ticks(in: SliderGeometry(width: width, height: 32), zeroProgress: nil).isEmpty)
    }

    @Test("A tick is hidden where a label sits or the handle passes")
    func hiddenNearLabelsAndHandle() {
        let tick = SliderTick(x: 100, isZero: false)
        #expect(SliderTicks.isClear(tick, of: [], handleX: 200))
        #expect(!SliderTicks.isClear(tick, of: [90 ... 130], handleX: 200))
        #expect(!SliderTicks.isClear(tick, of: [50 ... 96], handleX: 200))
        #expect(SliderTicks.isClear(tick, of: [50 ... 90], handleX: 200))
        #expect(!SliderTicks.isClear(tick, of: [], handleX: 104))
        #expect(SliderTicks.isClear(tick, of: [], handleX: 112))
    }
}
