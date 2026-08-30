import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// Smoothing the pointer without lying about where it clicked (docs/09 U3.2).
///
/// The two rules pull against each other, and the tests are mostly about the tension:
/// motion has to be smoothed or the recording looks amateurish, and presses have to be
/// exact or the recording appears to lie about what was clicked.
@Suite("Cursor reconstruction")
struct CursorReconstructionTests {
    private let reconstruction = CursorReconstruction()

    /// A pointer moving right in a straight line, with jitter on it.
    private func jitteryTelemetry(duration: TimeInterval = 2) -> InputTelemetry {
        var samples: [PointerSample] = []
        var time: TimeInterval = 0
        var index = 0
        while time <= duration {
            // A steady march with a saw-tooth wobble — the shape a hand-moved pointer has.
            let wobble: CGFloat = index.isMultiple(of: 2) ? 8 : -8
            samples.append(PointerSample(
                time: time,
                position: CGPoint(x: 100 + time * 200, y: 300 + wobble)
            ))
            time += 1.0 / 60
            index += 1
        }
        return InputTelemetry(pointer: samples)
    }

    // MARK: - Smoothing

    /// A recording that reproduces the jitter looks amateurish where the same recording
    /// smoothed looks deliberate.
    @Test("Jitter is smoothed out of the motion")
    func jitterIsSmoothed() {
        let telemetry = jitteryTelemetry()
        let path = reconstruction.path(for: telemetry, duration: 2)
        #expect(!path.isEmpty)

        // The recorded y-coordinate swings 16 points every frame; the smoothed one must
        // not.
        let swings = zip(path, path.dropFirst()).map { abs($1.y - $0.y) }
        let worst = swings.max() ?? 0
        #expect(worst < 4, "the smoothed path still jitters by \(worst)")
    }

    @Test("The smoothed path still follows the motion")
    func followsTheMotion() throws {
        let telemetry = jitteryTelemetry()
        let path = reconstruction.path(for: telemetry, duration: 2)

        let start = try #require(SpringIntegrator.sample(path, at: 0))
        let end = try #require(SpringIntegrator.sample(path, at: 1.9))
        #expect(end.x > start.x + 300, "the cursor should have travelled")
    }

    @Test("No telemetry means no path rather than a crash")
    func emptyTelemetry() {
        #expect(reconstruction.path(for: InputTelemetry(), duration: 5).isEmpty)
        #expect(reconstruction.cursor(at: 1, path: [], telemetry: InputTelemetry()) == nil)
    }

    // MARK: - Presses are exact

    /// A click drawn at the smoothed position lands *next to* the thing it opened, which
    /// makes the recording appear to lie about what was clicked.
    @Test("The cursor is exactly where the press was, at the instant of the press")
    func pressIsPixelExact() throws {
        var telemetry = jitteryTelemetry()
        let pressPosition = CGPoint(x: 640, y: 480)
        telemetry.clicks = [ClickEvent(time: 1, position: pressPosition)]

        let path = reconstruction.path(for: telemetry, duration: 2)
        let cursor = try #require(reconstruction.cursor(at: 1, path: path, telemetry: telemetry))

        #expect(abs(cursor.position.x - pressPosition.x) < 0.001)
        #expect(abs(cursor.position.y - pressPosition.y) < 0.001)
    }

    /// The snap is a correction, not a new home: a slow return would read as the cursor
    /// drifting away from what it just clicked.
    @Test("The correction eases out and is gone shortly after")
    func correctionEasesOut() throws {
        var telemetry = jitteryTelemetry()
        telemetry.clicks = [ClickEvent(time: 1, position: CGPoint(x: 640, y: 480))]
        let path = reconstruction.path(for: telemetry, duration: 2)

        let smoothed = try #require(SpringIntegrator.sample(path, at: 1 + CursorReconstruction.snapRecovery))
        let after = try #require(reconstruction.cursor(
            at: 1 + CursorReconstruction.snapRecovery,
            path: path,
            telemetry: telemetry
        ))
        #expect(abs(after.position.x - smoothed.x) < 0.001, "the correction should have released")
    }

    @Test("Midway through the recovery the cursor is between the two")
    func correctionIsPartway() throws {
        var telemetry = jitteryTelemetry()
        let pressPosition = CGPoint(x: 640, y: 480)
        telemetry.clicks = [ClickEvent(time: 1, position: pressPosition)]
        let path = reconstruction.path(for: telemetry, duration: 2)

        let midpoint = 1 + CursorReconstruction.snapRecovery / 2
        let smoothed = try #require(SpringIntegrator.sample(path, at: midpoint))
        let cursor = try #require(reconstruction.cursor(at: midpoint, path: path, telemetry: telemetry))

        let towardsPress = abs(cursor.position.x - pressPosition.x)
        let towardsSmoothed = abs(cursor.position.x - smoothed.x)
        #expect(towardsPress > 0, "it should have started returning")
        #expect(towardsSmoothed > 0, "but not arrived")
    }

    @Test("Away from any press the cursor is purely smoothed")
    func awayFromPresses() throws {
        var telemetry = jitteryTelemetry()
        telemetry.clicks = [ClickEvent(time: 0.2, position: CGPoint(x: 0, y: 0))]
        let path = reconstruction.path(for: telemetry, duration: 2)

        let smoothed = try #require(SpringIntegrator.sample(path, at: 1.5))
        let cursor = try #require(reconstruction.cursor(at: 1.5, path: path, telemetry: telemetry))
        #expect(abs(cursor.position.x - smoothed.x) < 0.001)
    }

    // MARK: - Ripples

    /// The ripple stays where the click happened even as the pointer moves on, because
    /// that is where the thing being clicked was.
    @Test("A ripple is anchored to the click, not to the cursor")
    func rippleIsAnchored() throws {
        var telemetry = jitteryTelemetry()
        let pressPosition = CGPoint(x: 640, y: 480)
        telemetry.clicks = [ClickEvent(time: 1, position: pressPosition)]
        let path = reconstruction.path(for: telemetry, duration: 2)

        let cursor = try #require(reconstruction.cursor(at: 1.3, path: path, telemetry: telemetry))
        #expect(cursor.clickPosition == pressPosition)
        #expect(cursor.position != pressPosition, "the cursor has moved on")
    }

    @Test("A ripple runs from nothing to done and then stops")
    func rippleProgress() throws {
        var telemetry = jitteryTelemetry()
        telemetry.clicks = [ClickEvent(time: 1, position: CGPoint(x: 640, y: 480))]
        let path = reconstruction.path(for: telemetry, duration: 3)

        let atPress = try #require(reconstruction.cursor(at: 1, path: path, telemetry: telemetry))
        #expect(atPress.clickProgress == 0)

        let midway = try #require(reconstruction.cursor(
            at: 1 + CursorReconstruction.clickDuration / 2,
            path: path,
            telemetry: telemetry
        ))
        #expect((midway.clickProgress ?? 0) > 0.4)

        let after = try #require(reconstruction.cursor(at: 2.5, path: path, telemetry: telemetry))
        #expect(after.clickProgress == nil)
    }

    @Test("A button going up is not a ripple")
    func releasesDoNotRipple() throws {
        var telemetry = jitteryTelemetry()
        telemetry.clicks = [ClickEvent(time: 1, position: .zero, button: .left, isDown: false)]
        let path = reconstruction.path(for: telemetry, duration: 2)

        let cursor = try #require(reconstruction.cursor(at: 1.1, path: path, telemetry: telemetry))
        #expect(cursor.clickProgress == nil)
    }

    // MARK: - Cursor artwork

    /// A cursor changes at an instant and stays changed; interpolating between two cursor
    /// *images* is not a thing.
    @Test("The cursor image is the last one set, not an interpolation")
    func cursorImageIsStepped() throws {
        let telemetry = InputTelemetry(pointer: [
            PointerSample(time: 0, position: .zero, cursorIndex: 0),
            PointerSample(time: 1, position: CGPoint(x: 100, y: 0), cursorIndex: 1)
        ])
        let path = reconstruction.path(for: telemetry, duration: 2)

        #expect(try #require(reconstruction.cursor(at: 0.5, path: path, telemetry: telemetry)).cursorIndex == 0)
        #expect(try #require(reconstruction.cursor(at: 1.5, path: path, telemetry: telemetry)).cursorIndex == 1)
    }
}

/// The metrics the preview and the export both read (docs/09 U3.2).
///
/// One place, because the two drawing these at slightly different sizes is the classic way
/// a studio export surprises somebody.
@Suite("Click ripple metrics")
struct ClickRippleMetricsTests {
    @Test("A ripple grows over its life")
    func rippleGrows() {
        #expect(ClickRippleMetrics.radiusFraction(at: 0) < ClickRippleMetrics.radiusFraction(at: 0.5))
        #expect(ClickRippleMetrics.radiusFraction(at: 0.5) < ClickRippleMetrics.radiusFraction(at: 1))
    }

    /// Fast out, slow finish: a ripple that expands linearly reads as a growing circle
    /// rather than as an impact.
    @Test("It expands fast and finishes slowly")
    func rippleEases() {
        let firstHalf = ClickRippleMetrics.radiusFraction(at: 0.5) - ClickRippleMetrics.radiusFraction(at: 0)
        let secondHalf = ClickRippleMetrics.radiusFraction(at: 1) - ClickRippleMetrics.radiusFraction(at: 0.5)
        #expect(firstHalf > secondHalf)
    }

    @Test("It fades out completely")
    func rippleFades() {
        #expect(ClickRippleMetrics.opacity(at: 0) == 1)
        #expect(ClickRippleMetrics.opacity(at: 1) == 0)
    }

    @Test("Progress outside its life is clamped rather than extrapolated")
    func rippleClamps() {
        #expect(ClickRippleMetrics.opacity(at: -5) == 1)
        #expect(ClickRippleMetrics.opacity(at: 99) == 0)
        #expect(ClickRippleMetrics.radiusFraction(at: 99) == ClickRippleMetrics.radiusFraction(at: 1))
    }

    /// A caption that starts dimming immediately is hard to read, which defeats showing it.
    @Test("A caption is held solid before it fades")
    func captionHoldsThenFades() {
        #expect(ClickRippleMetrics.captionOpacity(elapsed: 0) == 1)
        #expect(ClickRippleMetrics.captionOpacity(elapsed: 0.5) == 1)
        #expect(ClickRippleMetrics.captionOpacity(elapsed: ClickRippleMetrics.captionDuration) == 0)
    }

    @Test("A caption is gone once its time is up")
    func captionExpires() {
        #expect(ClickRippleMetrics.captionOpacity(elapsed: 99) == 0)
        #expect(ClickRippleMetrics.captionOpacity(elapsed: -1) == 0)
    }
}

/// The spring both the cursor and the camera use (docs/09 U3.2, U3.3).
@Suite("Motion spring")
struct MotionSpringTests {
    @Test("A spring converges on its target")
    func converges() {
        let spring = MotionSpring()
        var position = 0.0
        for _ in 0 ..< 240 {
            position = spring.advance(position, towards: 100, by: MotionSpring.step)
        }
        #expect(abs(position - 100) < 1)
    }

    /// Overshoot on a cursor looks like the pointer sliding past what it clicked, which is
    /// worse than being slightly late.
    @Test("It never overshoots")
    func neverOvershoots() {
        let spring = MotionSpring()
        var position = 0.0
        for _ in 0 ..< 1000 {
            position = spring.advance(position, towards: 100, by: MotionSpring.step)
            #expect(position <= 100.0001, "overshot to \(position)")
        }
    }

    @Test("A stiffer spring arrives sooner")
    func stiffnessMatters() {
        func distanceAfterHalfASecond(stiffness: Double) -> Double {
            let spring = MotionSpring(stiffness: stiffness)
            var position = 0.0
            for _ in 0 ..< 120 {
                position = spring.advance(position, towards: 100, by: MotionSpring.step)
            }
            return position
        }
        #expect(distanceAfterHalfASecond(stiffness: 30) > distanceAfterHalfASecond(stiffness: 5))
    }

    @Test("A zero-length step changes nothing")
    func zeroStep() {
        #expect(MotionSpring().advance(10, towards: 100, by: 0) == 10)
    }

    /// A 30 fps and a 60 fps render of the same edit must move identically, which they do
    /// only if the integration is at a fixed rate and the sampling is separate from it.
    @Test("Sampling the same integration at different rates agrees")
    func rateIndependence() throws {
        let integrator = SpringIntegrator()
        let targets: [(time: TimeInterval, value: CGPoint)] = [
            (0, CGPoint(x: 0, y: 0)),
            (0.5, CGPoint(x: 500, y: 0)),
            (1, CGPoint(x: 200, y: 300))
        ]
        let path = integrator.integrate(targets: targets, duration: 2)

        for frame in 0 ..< 30 {
            let time = Double(frame) / 30
            let atThirty = try #require(SpringIntegrator.sample(path, at: time))
            let atSixty = try #require(SpringIntegrator.sample(path, at: time))
            #expect(atThirty == atSixty)
        }
    }

    @Test("An integration with no targets is empty rather than a crash")
    func emptyIntegration() {
        #expect(SpringIntegrator().integrate(targets: [], duration: 5).isEmpty)
        #expect(SpringIntegrator().integrate(targets: [(0, .zero)], duration: 0).isEmpty)
    }

    @Test("Sampling before the start and past the end is clamped")
    func samplingOutOfRange() throws {
        let path = SpringIntegrator().integrate(targets: [(0, CGPoint(x: 5, y: 5))], duration: 1)
        #expect(try #require(SpringIntegrator.sample(path, at: -1)) == path[0])
        #expect(try #require(SpringIntegrator.sample(path, at: 99)) == path[path.count - 1])
        #expect(SpringIntegrator.sample([], at: 0) == nil)
    }
}
