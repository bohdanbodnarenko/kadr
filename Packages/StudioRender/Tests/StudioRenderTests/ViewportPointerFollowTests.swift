import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// Following the pointer is an explicit zoom mode, not the default (docs/09 U3.3).
@Suite("Pointer-follow zooms")
struct ViewportPointerFollowTests {
    private let size = CGSize(width: 1920, height: 1080)
    private var centre: CGPoint {
        CGPoint(x: 960, y: 540)
    }

    @Test("A pointer-follow cue aims at the sample in force at that instant")
    func targetTracksThePointer() {
        let cue = ZoomCue(start: 0, duration: 4, magnification: 2, anchor: .pointer)
        let samples = [
            PointerSample(time: 0, position: CGPoint(x: 100, y: 540)),
            PointerSample(time: 2, position: CGPoint(x: 1800, y: 540))
        ]
        let early = ViewportTimeline.target(
            at: 0.5,
            cues: [cue],
            size: size,
            centre: centre,
            pointer: samples
        )
        let late = ViewportTimeline.target(
            at: 2.5,
            cues: [cue],
            size: size,
            centre: centre,
            pointer: samples
        )
        #expect(early.centre.x == 100)
        #expect(late.centre.x == 1800)
    }

    @Test("Without pointer samples a follow cue aims at the middle of the frame")
    func missingSamplesFallBackToCentre() {
        let cue = ZoomCue(start: 0, duration: 2, magnification: 2, anchor: .pointer)
        let viewport = ViewportTimeline.target(
            at: 1,
            cues: [cue],
            size: size,
            centre: centre,
            pointer: []
        )
        #expect(viewport.centre == centre)
    }

    @Test("The smoothed camera moves when the pointer does")
    func timelineFollowsThePointer() {
        let cue = ZoomCue(start: 0, duration: 4, magnification: 2, anchor: .pointer)
        let samples = [
            PointerSample(time: 0, position: CGPoint(x: 200, y: 540)),
            PointerSample(time: 2, position: CGPoint(x: 1700, y: 540))
        ]
        let timeline = ViewportTimeline(
            cues: [cue],
            size: size,
            duration: 5,
            pointer: samples
        )
        let early = timeline.viewport(at: 0.4).centre
        let late = timeline.viewport(at: 2.8).centre
        #expect(late.x > early.x + 200, "expected the camera to travel with the pointer")
    }

    @Test("A pointer-follow cue round-trips")
    func pointerCueRoundTrips() throws {
        let cue = ZoomCue(start: 1, duration: 2, magnification: 2, anchor: .pointer)
        let data = try JSONEncoder().encode(cue)
        #expect(try JSONDecoder().decode(ZoomCue.self, from: data) == cue)
    }

    @Test("A crop does not pin a pointer-follow cue to a fixed point")
    func cropKeepsPointerFollow() {
        var cropped = StudioEdit.untouched(duration: 4)
        cropped.zooms = [ZoomCue(start: 0, duration: 4, magnification: 2, anchor: .pointer)]
        cropped.cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let samples = [
            PointerSample(time: 0, position: CGPoint(x: 520, y: 540)),
            PointerSample(time: 2, position: CGPoint(x: 1400, y: 540))
        ]
        let plan = StudioRenderPlan(edit: cropped, sourceSize: size, pointer: samples)
        let early = plan.viewports.viewport(at: 0.3).centre
        let late = plan.viewports.viewport(at: 2.6).centre
        #expect(late.x > early.x + 100)
    }

    @Test("Edge-in-frame bias keeps a corner pointer off the center of the zoom")
    func boundsBiasPullsAwayFromThePointer() {
        let cue = ZoomCue(
            start: 0,
            duration: 4,
            magnification: 2,
            anchor: .pointer,
            boundsBias: 1
        )
        let samples = [PointerSample(time: 0, position: CGPoint(x: 100, y: 540))]
        let aimed = ViewportTimeline.target(
            at: 0.5,
            cues: [cue],
            size: size,
            centre: centre,
            pointer: samples
        )
        #expect(aimed.centre.x > 400, "bias 1 should keep a left-edge pointer from the zoom center")
        #expect(aimed.centre.x < 960)
    }

    @Test("Zero bias still aims straight at the pointer")
    func zeroBiasStaysOnThePointer() {
        var cue = ZoomCue(start: 0, duration: 4, magnification: 2, anchor: .pointer, boundsBias: 1)
        cue.boundsBias = 0
        let samples = [PointerSample(time: 0, position: CGPoint(x: 100, y: 540))]
        let aimed = ViewportTimeline.target(
            at: 0.5,
            cues: [cue],
            size: size,
            centre: centre,
            pointer: samples
        )
        #expect(aimed.centre.x == 100)
    }

    @Test("Bounds bias is clamped to the unit interval")
    func boundsBiasIsClamped() {
        #expect(ZoomCue(start: 0, duration: 1, boundsBias: 4).boundsBias == 1)
        #expect(ZoomCue(start: 0, duration: 1, boundsBias: -1).boundsBias == 0)
    }
}
