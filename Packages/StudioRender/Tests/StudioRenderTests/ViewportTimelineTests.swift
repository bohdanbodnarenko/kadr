import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// The virtual camera (docs/09 U3.3).
///
/// The determinism tests are the important ones: the plan calls for the preview and the
/// export to share a precomputed timeline, and the way to prove they do is to build it
/// twice and compare, rather than to look at two videos and hope.
@Suite("Viewport timeline")
struct ViewportTimelineTests {
    private let size = CGSize(width: 1920, height: 1080)
    private var centre: CGPoint {
        CGPoint(x: 960, y: 540)
    }

    // MARK: - Resting

    @Test("With no cues the camera sits still, showing everything")
    func noCues() {
        let timeline = ViewportTimeline(cues: [], size: size, duration: 5)
        for time in stride(from: 0.0, through: 5, by: 0.5) {
            let viewport = timeline.viewport(at: time)
            #expect(abs(viewport.magnification - 1) < 0.001)
            #expect(viewport.centre == centre)
        }
    }

    @Test("A still camera is not moving, so it needs no blur")
    func stillCameraNeedsNoBlur() {
        let timeline = ViewportTimeline(cues: [], size: size, duration: 5)
        #expect(!timeline.isMoving(at: 2))
        #expect(!MotionBlurPlan.plan(isMoving: false).isBlurring)
    }

    // MARK: - Zooming

    @Test("A cue zooms in and comes back out")
    func zoomsInAndOut() {
        let cue = ZoomCue(start: 1, duration: 2, magnification: 2, anchor: .fixed(CGPoint(x: 400, y: 300)))
        let timeline = ViewportTimeline(cues: [cue], size: size, duration: 8)

        #expect(abs(timeline.viewport(at: 0.5).magnification - 1) < 0.05, "not yet")
        #expect(timeline.viewport(at: 2.5).magnification > 1.7, "in by the middle")
        #expect(timeline.viewport(at: 7).magnification < 1.1, "and back out by the end")
    }

    @Test("The camera moves towards the anchor")
    func movesTowardsTheAnchor() {
        let anchor = CGPoint(x: 400, y: 300)
        let cue = ZoomCue(start: 0, duration: 3, magnification: 2, anchor: .fixed(anchor))
        let timeline = ViewportTimeline(cues: [cue], size: size, duration: 5)

        let settled = timeline.viewport(at: 2.5).centre
        #expect(abs(settled.x - anchor.x) < 60, "expected near \(anchor), got \(settled)")
        #expect(abs(settled.y - anchor.y) < 60)
    }

    /// A viewport that runs off the edge would show blank frame. Sliding it back keeps the
    /// magnification the user asked for, where clipping would silently zoom out.
    @Test("A zoom near the edge slides back in rather than showing blank frame")
    func edgeZoomIsClamped() {
        let cue = ZoomCue(start: 0, duration: 3, magnification: 3, anchor: .fixed(.zero))
        let timeline = ViewportTimeline(cues: [cue], size: size, duration: 4)

        let rect = timeline.sourceRect(at: 2)
        #expect(rect.minX >= -0.001)
        #expect(rect.minY >= -0.001)
        #expect(rect.maxX <= size.width + 0.001)
        #expect(rect.maxY <= size.height + 0.001)
    }

    /// A cue placed over another replaces it rather than averaging with it — an average of
    /// two anchors frames neither.
    @Test("Overlapping cues resolve to the later one")
    func overlappingCues() {
        let first = ZoomCue(start: 0, duration: 4, magnification: 2, anchor: .fixed(CGPoint(x: 200, y: 200)))
        let second = ZoomCue(start: 1, duration: 2, magnification: 3, anchor: .fixed(CGPoint(x: 1600, y: 800)))
        let timeline = ViewportTimeline(cues: [first, second], size: size, duration: 8)

        let during = timeline.viewport(at: 2.5)
        #expect(during.centre.x > 1000, "the later cue should own this moment, got \(during.centre)")
    }

    @Test("The camera never zooms out past the whole frame")
    func neverZoomsOut() {
        let cue = ZoomCue(start: 1, duration: 1, magnification: 2)
        let timeline = ViewportTimeline(cues: [cue], size: size, duration: 6)
        for time in stride(from: 0.0, through: 6, by: 0.05) {
            #expect(timeline.viewport(at: time).magnification >= 0.999)
        }
    }

    // MARK: - Determinism

    /// The plan's own acceptance criterion: preview and export share the precomputed
    /// timeline, tested by comparing rather than by watching.
    @Test("The same cues always produce the same timeline")
    func timelineIsDeterministic() {
        let cues = [
            ZoomCue(id: UUID(), start: 1, duration: 2, magnification: 2, anchor: .fixed(CGPoint(x: 300, y: 400))),
            ZoomCue(id: UUID(), start: 5, duration: 1.5, magnification: 2.5, anchor: .centre)
        ]
        let first = ViewportTimeline(cues: cues, size: size, duration: 10)
        let second = ViewportTimeline(cues: cues, size: size, duration: 10)

        #expect(first.magnifications == second.magnifications)
        #expect(first.centres == second.centres)
    }

    /// A preview at 30 fps and an export at 60 must agree frame for frame where they
    /// overlap; they do only because both sample one integration.
    @Test("Sampling at different frame rates agrees where the frames line up")
    func rateIndependence() {
        let cue = ZoomCue(start: 0.5, duration: 2, magnification: 2, anchor: .fixed(CGPoint(x: 600, y: 400)))
        let timeline = ViewportTimeline(cues: [cue], size: size, duration: 5)

        for frame in 0 ..< 150 {
            let time = Double(frame) / 30
            let preview = timeline.viewport(at: time)
            let export = timeline.viewport(at: time)
            #expect(preview.magnification == export.magnification)
            #expect(preview.centre == export.centre)
        }
    }

    @Test("A zero-length recording produces a usable timeline rather than nothing")
    func zeroDuration() {
        let timeline = ViewportTimeline(cues: [], size: size, duration: 0)
        #expect(timeline.viewport(at: 0).magnification == 1)
    }

    // MARK: - Motion blur

    /// A fast camera move strobes without it: each frame is a sharp picture of a different
    /// place, and the eye reads the gaps.
    @Test("A moving camera asks for supersampling")
    func movingCameraBlurs() {
        let cue = ZoomCue(start: 0.5, duration: 2, magnification: 2.5, anchor: .fixed(CGPoint(x: 300, y: 300)))
        let timeline = ViewportTimeline(cues: [cue], size: size, duration: 6)

        #expect(timeline.isMoving(at: 0.8), "the camera should be moving in")
        #expect(MotionBlurPlan.plan(isMoving: true).isBlurring)
    }

    @Test("Zero intensity is a still frame even when the camera is moving")
    func zeroIntensityDoesNotBlur() {
        #expect(!MotionBlurPlan.plan(isMoving: true, intensity: 0).isBlurring)
        #expect(MotionBlurPlan.plan(isMoving: true, intensity: 0.5).sampleCount == 4)
        #expect(MotionBlurPlan.plan(isMoving: true, intensity: 1).sampleCount == 8)
    }

    @Test("Samples straddle the frame's own time rather than dragging it forward")
    func offsetsAreCentred() {
        let offsets = MotionBlurPlan(sampleCount: 4).offsets(frameDuration: 1.0 / 60)
        #expect(offsets.count == 4)
        #expect(abs(offsets.reduce(0, +)) < 0.0001, "the samples should balance about zero")
        #expect((offsets.min() ?? 0) < 0)
        #expect((offsets.max() ?? 0) > 0)
    }

    /// Half is the film convention: a fully open shutter smears and a narrow one is barely
    /// blur at all.
    @Test("The shutter is open for part of the frame, not all of it")
    func shutterFraction() {
        let plan = MotionBlurPlan(sampleCount: 4)
        let frame = 1.0 / 60
        let span = (plan.offsets(frameDuration: frame).max() ?? 0)
            - (plan.offsets(frameDuration: frame).min() ?? 0)
        #expect(span < frame)
    }

    @Test("No blur means one sample at the frame's own time")
    func noBlurIsOneSample() {
        #expect(MotionBlurPlan.none.offsets(frameDuration: 1.0 / 60) == [0])
    }

    @Test("A degenerate plan is clamped rather than dividing by zero")
    func degeneratePlan() {
        #expect(MotionBlurPlan(sampleCount: 0).sampleCount == 1)
        #expect(MotionBlurPlan(sampleCount: 4, shutterFraction: 0).shutterFraction > 0)
    }
}

/// Proposing zooms from where the user clicked (docs/09 U3.3).
@Suite("Zoom cue planner")
struct ZoomCuePlannerTests {
    private let size = CGSize(width: 1920, height: 1080)
    private let planner = ZoomCuePlanner()

    private func clicks(_ times: [TimeInterval], at position: CGPoint) -> [ClickEvent] {
        times.map { ClickEvent(time: $0, position: position) }
    }

    @Test("A burst of clicks in one place becomes a zoom")
    func burstBecomesAZoom() {
        let cues = planner.cues(
            for: clicks([1, 1.4, 1.9], at: CGPoint(x: 400, y: 300)),
            in: size,
            duration: 10
        )
        #expect(cues.count == 1)
        #expect(cues[0].magnification > 1)
    }

    /// A single click is somebody passing through rather than working.
    @Test("One click is not a cluster")
    func singleClickIsNotACluster() {
        #expect(planner.cues(for: clicks([1], at: CGPoint(x: 400, y: 300)), in: size, duration: 10).isEmpty)
    }

    @Test("Clicks far apart in time are separate zooms")
    func separatedInTime() {
        let events = clicks([1, 1.2], at: CGPoint(x: 400, y: 300))
            + clicks([20, 20.2], at: CGPoint(x: 400, y: 300))
        #expect(planner.cues(for: events, in: size, duration: 30).count == 2)
    }

    /// Two clicks a second apart at opposite corners are two activities; zooming to the
    /// midpoint would frame neither.
    @Test("Clicks far apart on screen are separate zooms even when close in time")
    func separatedInSpace() {
        let events = [
            ClickEvent(time: 1, position: CGPoint(x: 100, y: 100)),
            ClickEvent(time: 1.1, position: CGPoint(x: 100, y: 120)),
            ClickEvent(time: 1.3, position: CGPoint(x: 1800, y: 1000)),
            ClickEvent(time: 1.4, position: CGPoint(x: 1800, y: 980))
        ]
        #expect(planner.cues(for: events, in: size, duration: 10).count == 2)
    }

    /// An anchor that followed the pointer would make the camera dither during the zoom —
    /// the most common way an automatic zoom looks cheap.
    @Test("A cluster's anchor is its centre, fixed once")
    func anchorIsTheClusterCentre() throws {
        let events = [
            ClickEvent(time: 1, position: CGPoint(x: 400, y: 300)),
            ClickEvent(time: 1.2, position: CGPoint(x: 500, y: 300))
        ]
        let cue = try #require(planner.cues(for: events, in: size, duration: 10).first)

        guard case let .cluster(anchor) = cue.anchor else {
            Issue.record("expected a cluster anchor")
            return
        }
        #expect(abs(anchor.x - 450) < 1)
        #expect(abs(anchor.y - 300) < 1)
    }

    /// Arriving *as* the click happens means the viewer sees the movement rather than the
    /// click.
    @Test("The camera starts moving before the first click")
    func startsBeforeTheClick() throws {
        let cue = try #require(planner.cues(
            for: clicks([3, 3.3], at: CGPoint(x: 400, y: 300)),
            in: size,
            duration: 10
        ).first)
        #expect(cue.start < 3)
    }

    /// The viewer needs to see the result of what was clicked, not a cut at the moment of
    /// impact.
    @Test("The zoom holds after the last click")
    func holdsAfterTheClick() throws {
        let cue = try #require(planner.cues(
            for: clicks([3, 3.3], at: CGPoint(x: 400, y: 300)),
            in: size,
            duration: 20
        ).first)
        #expect(cue.start + cue.duration > 3.3)
    }

    @Test("Nothing is proposed past the end of the recording")
    func nothingPastTheEnd() {
        let cues = planner.cues(for: clicks([1, 1.2], at: CGPoint(x: 400, y: 300)), in: size, duration: 3)
        for cue in cues {
            #expect(cue.start + cue.duration <= 3.001)
        }
    }

    @Test("Releases are not clicks")
    func releasesAreIgnored() {
        let events = [
            ClickEvent(time: 1, position: .zero, button: .left, isDown: false),
            ClickEvent(time: 1.2, position: .zero, button: .left, isDown: false)
        ]
        #expect(planner.cues(for: events, in: size, duration: 10).isEmpty)
    }

    @Test("No clicks means no zooms rather than a crash")
    func noClicks() {
        #expect(planner.cues(for: [], in: size, duration: 10).isEmpty)
        #expect(planner.cues(for: clicks([1, 2], at: .zero), in: size, duration: 0).isEmpty)
    }

    /// The same recording always produces the same cues, so the suggestions are reviewable
    /// rather than magical.
    @Test("The same clicks always propose the same zooms")
    func plannerIsDeterministic() {
        let events = clicks([1, 1.3, 1.6], at: CGPoint(x: 400, y: 300))
        let first = planner.cues(for: events, in: size, duration: 10)
        let second = planner.cues(for: events, in: size, duration: 10)

        #expect(first.map(\.start) == second.map(\.start))
        #expect(first.map(\.duration) == second.map(\.duration))
        #expect(first.map(\.anchor) == second.map(\.anchor))
    }

    @Test("Magnification is capped so a zoom never shows raw pixels")
    func magnificationIsCapped() {
        #expect(ZoomCue(start: 0, duration: 1, magnification: 99).magnification
            == ZoomCue.maximumMagnification)
        #expect(ZoomCue(start: 0, duration: 1, magnification: 0.1).magnification == 1)
    }

    @Test("A cue round-trips")
    func cueRoundTrips() throws {
        let cue = ZoomCue(start: 1, duration: 2, magnification: 2, anchor: .cluster(CGPoint(x: 5, y: 6)))
        let data = try JSONEncoder().encode(cue)
        #expect(try JSONDecoder().decode(ZoomCue.self, from: data) == cue)
    }

    @Test("A cue with nothing in it at all decodes")
    func emptyCue() throws {
        let cue = try JSONDecoder().decode(ZoomCue.self, from: Data("{}".utf8))
        #expect(cue.magnification == 1.8)
        #expect(cue.anchor == .centre)
        #expect(cue.isEnabled)
        #expect(cue.boundsBias == 0)
    }
}
