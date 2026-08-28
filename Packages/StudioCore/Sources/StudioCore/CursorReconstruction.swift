import CoreGraphics
import Foundation

/// Where the cursor is at one moment of the finished video (docs/09 U3.2).
public struct ReconstructedCursor: Sendable, Hashable {
    /// In the recorded area's own pixels.
    public var position: CGPoint
    /// Which cursor artwork to draw, as an index into the session's images.
    public var cursorIndex: Int?
    /// How far through a click's ripple this frame is, 0…1, or nil when there is none.
    public var clickProgress: Double?
    /// Where the ripple is centred. A click's ripple stays where the click happened even
    /// as the pointer moves on, because that is where the thing being clicked was.
    public var clickPosition: CGPoint?

    public init(
        position: CGPoint,
        cursorIndex: Int? = nil,
        clickProgress: Double? = nil,
        clickPosition: CGPoint? = nil
    ) {
        self.position = position
        self.cursorIndex = cursorIndex
        self.clickProgress = clickProgress
        self.clickPosition = clickPosition
    }
}

/// Turns telemetry into a cursor to draw (docs/09 U3.2).
///
/// Two rules, and they pull against each other, which is why this is not simply "smooth
/// everything":
///
/// * **Motion is smoothed.** A hand-moved pointer jitters, and a recording that reproduces
///   the jitter looks amateurish where the same recording smoothed looks deliberate.
/// * **Presses are pixel-exact.** A smoothed cursor arrives at a button slightly late, and
///   a click drawn at the smoothed position lands *next to* the thing it opened. That is
///   worse than jitter: it makes the recording appear to lie about what was clicked.
///
/// So the smoothed path is snapped back to the recorded position at the instant of every
/// press, and eased back out afterwards. The result moves smoothly and clicks exactly.
public struct CursorReconstruction: Sendable {
    /// How long a click's ripple lasts.
    public static let clickDuration: TimeInterval = 0.45
    /// How long the cursor takes to return to its smoothed path after a press.
    ///
    /// Short: the snap is a correction, and a slow return would read as the cursor
    /// drifting away from what it just clicked.
    public static let snapRecovery: TimeInterval = 0.12

    public var spring: MotionSpring

    public init(spring: MotionSpring = MotionSpring()) {
        self.spring = spring
    }

    /// The smoothed, click-corrected path for a whole recording.
    ///
    /// Computed once for a session and sampled by both the preview and the export, which
    /// is what makes them identical rather than merely similar.
    public func path(for telemetry: InputTelemetry, duration: TimeInterval) -> [CGPoint] {
        let targets = telemetry.pointer.map { (time: $0.time, value: $0.position) }
        guard !targets.isEmpty else { return [] }
        return SpringIntegrator(spring: spring).integrate(targets: targets, duration: duration)
    }

    /// What to draw at `time`.
    ///
    /// - Parameters:
    ///   - path: the integration from `path(for:duration:)`.
    ///   - telemetry: the recorded events, for the exact positions and the ripples.
    public func cursor(
        at time: TimeInterval,
        path: [CGPoint],
        telemetry: InputTelemetry
    ) -> ReconstructedCursor? {
        guard let smoothed = SpringIntegrator.sample(path, at: time) else { return nil }

        let press = mostRecentPress(before: time, in: telemetry)
        let position = correcting(smoothed, towards: press, at: time)

        return ReconstructedCursor(
            position: position,
            cursorIndex: cursorIndex(at: time, in: telemetry),
            clickProgress: press.flatMap { clickProgress(at: time, press: $0) },
            clickPosition: press?.position
        )
    }

    /// The press whose ripple is still running, if any.
    private func mostRecentPress(before time: TimeInterval, in telemetry: InputTelemetry) -> ClickEvent? {
        telemetry.clicks
            .last { $0.isDown && $0.time <= time && time - $0.time <= Self.clickDuration }
    }

    /// Snaps the smoothed position back to where the press actually was, easing out.
    ///
    /// The correction is full at the instant of the press and gone by `snapRecovery`, so
    /// the cursor is exactly right when it matters and smooth the rest of the time.
    private func correcting(_ smoothed: CGPoint, towards press: ClickEvent?, at time: TimeInterval) -> CGPoint {
        guard let press else { return smoothed }
        let elapsed = time - press.time
        guard elapsed >= 0, elapsed < Self.snapRecovery else { return smoothed }

        // Cosine ease-out: one at the press, zero at the end of the recovery, with no
        // corner at either end — a linear blend leaves a visible kink where it releases.
        let fraction = elapsed / Self.snapRecovery
        let weight = (cos(fraction * .pi) + 1) / 2
        return CGPoint(
            x: smoothed.x + (press.position.x - smoothed.x) * weight,
            y: smoothed.y + (press.position.y - smoothed.y) * weight
        )
    }

    /// How far through its ripple a press is, or nil once it is over.
    private func clickProgress(at time: TimeInterval, press: ClickEvent) -> Double? {
        let elapsed = time - press.time
        guard elapsed >= 0, elapsed <= Self.clickDuration else { return nil }
        return elapsed / Self.clickDuration
    }

    /// Which cursor image was showing at `time`.
    ///
    /// The last sample at or before now, because a cursor changes at an instant and stays
    /// changed — interpolating between two cursor *images* is not a thing.
    private func cursorIndex(at time: TimeInterval, in telemetry: InputTelemetry) -> Int? {
        telemetry.pointer.last { $0.time <= time }?.cursorIndex
    }
}

/// How big to draw the ripple and the caption (docs/09 U3.2).
///
/// Shared metrics, in one place, because the preview and the export drawing these at
/// slightly different sizes is the classic way a studio export surprises somebody. Both
/// read from here; neither has numbers of its own.
public enum ClickRippleMetrics {
    /// The ripple's radius at `progress`, as a fraction of the recorded area's shortest
    /// edge — normalized like every other metric in Kadr so it carries between resolutions.
    public static func radiusFraction(at progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        // Fast out, slow finish: a ripple that expands linearly reads as a growing circle
        // rather than as an impact.
        return 0.012 + 0.028 * (1 - pow(1 - clamped, 2))
    }

    /// How visible the ripple is at `progress`. Fades out over its life.
    public static func opacity(at progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 1 - clamped
    }

    /// The ripple's stroke width, likewise normalized.
    public static func strokeFraction(at progress: Double) -> Double {
        0.004 * (1 - min(max(progress, 0), 1) * 0.5)
    }

    /// How long a keystroke caption stays on screen.
    public static let captionDuration: TimeInterval = 1.4

    /// A caption's opacity at `elapsed` seconds after the press.
    ///
    /// Held solid and then faded, rather than faded throughout: a caption that starts
    /// dimming immediately is hard to read, which defeats the point of showing it.
    public static func captionOpacity(elapsed: TimeInterval) -> Double {
        guard elapsed >= 0, elapsed <= captionDuration else { return 0 }
        let fadeStart = captionDuration * 0.65
        guard elapsed > fadeStart else { return 1 }
        return 1 - (elapsed - fadeStart) / (captionDuration - fadeStart)
    }
}
