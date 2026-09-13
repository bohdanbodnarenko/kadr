import CoreGraphics
import Foundation
import StudioSession

/// Where the camera is at one instant (docs/09 U3.3).
public struct Viewport: Sendable, Hashable {
    /// How far in. 1 is the whole frame.
    public var magnification: Double
    /// What is at the centre of the frame, in the recorded area's pixels.
    public var centre: CGPoint

    public init(magnification: Double = 1, centre: CGPoint) {
        self.magnification = max(magnification, 1)
        self.centre = centre
    }

    /// The part of the recorded area this viewport shows.
    public func sourceRect(in size: CGSize) -> CGRect {
        let width = size.width / magnification
        let height = size.height / magnification
        return CGRect(
            x: centre.x - width / 2,
            y: centre.y - height / 2,
            width: width,
            height: height
        )
    }

    /// The same, kept inside the recorded area.
    ///
    /// A viewport that runs off the edge would show blank frame, so it is slid back in
    /// rather than clipped — sliding keeps the magnification the user asked for, where
    /// clipping would silently zoom out.
    public func clampedSourceRect(in size: CGSize) -> CGRect {
        var rect = sourceRect(in: size)
        rect.origin.x = min(max(rect.minX, 0), max(size.width - rect.width, 0))
        rect.origin.y = min(max(rect.minY, 0), max(size.height - rect.height, 0))
        return rect
    }
}

/// Every frame's camera position, computed once (docs/09 U3.3).
///
/// Precomputed rather than evaluated per frame, and shared by the preview and the export.
/// That is what makes them identical: a preview that interpolates cues its own way is a
/// preview that lies, and the difference only shows up after a five-minute render.
///
/// The spring is the same one the cursor uses, so the camera and the pointer settle
/// together instead of one chasing the other.
public struct ViewportTimeline: Sendable {
    /// The camera's position at each fixed step from zero.
    public let magnifications: [Double]
    public let centres: [CGPoint]
    public let duration: TimeInterval
    private let size: CGSize

    /// Builds the timeline for a set of cues.
    ///
    /// - Parameters:
    ///   - cues: the zooms, in edited time.
    ///   - size: the recorded area.
    ///   - duration: the edited recording's length.
    ///   - spring: how snappy the camera is. The plan supplies the edit's zoom style;
    ///     the cursor uses its own spring so the two looks stay independent.
    ///   - pointer: edited-time samples, used only by cues whose anchor follows the pointer.
    public init(
        cues: [ZoomCue],
        size: CGSize,
        duration: TimeInterval,
        spring: MotionSpring = MotionSpring(),
        pointer: [PointerSample] = []
    ) {
        self.size = size
        self.duration = max(duration, 0)

        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let steps = max(Int(self.duration / MotionSpring.step) + 1, 1)
        let ordered = cues.sorted { $0.start < $1.start }
        let pointer = pointer.sorted { $0.time < $1.time }

        var magnifications: [Double] = []
        var centres: [CGPoint] = []
        magnifications.reserveCapacity(steps)
        centres.reserveCapacity(steps)

        var magnification = 1.0
        var position = centre

        for step in 0 ..< steps {
            let time = Double(step) * MotionSpring.step
            let target = Self.target(
                at: time,
                cues: ordered,
                size: size,
                centre: centre,
                pointer: pointer
            )
            // Springs rather than a curve per cue: overlapping cues then blend instead of
            // fighting, and a cue deleted mid-transition eases away rather than snapping.
            magnification = spring.advance(magnification, towards: target.magnification, by: MotionSpring.step)
            position = spring.advance(position, towards: target.centre, by: MotionSpring.step)
            magnifications.append(magnification)
            centres.append(position)
        }

        self.magnifications = magnifications
        self.centres = centres
    }

    /// What the camera is aiming at, before smoothing.
    ///
    /// A cue's magnification applies across its whole range including its transitions; the
    /// spring is what turns the step into a move. Doing it the other way — easing the
    /// target and then smoothing it — eases twice and arrives late.
    static func target(
        at time: TimeInterval,
        cues: [ZoomCue],
        size: CGSize,
        centre: CGPoint,
        pointer: [PointerSample]
    ) -> Viewport {
        // The last cue that contains this moment wins, so a cue placed over another
        // replaces it rather than averaging with it.
        guard let cue = cues.last(where: { $0.range.contains(time) }) else {
            return Viewport(magnification: 1, centre: centre)
        }
        let aim: CGPoint = if cue.anchor.followsPointer {
            Self.pointerAim(
                at: Self.pointerPosition(at: time, in: pointer) ?? centre,
                in: size,
                magnification: cue.magnification,
                boundsBias: cue.boundsBias
            )
        } else {
            cue.anchor.point(in: size)
        }
        return Viewport(magnification: cue.magnification, centre: aim)
    }

    /// Where pointer-follow aims, after "Edge in Frame" (docs/09 U3.3).
    ///
    /// Bias 0 centres the pointer. Bias 1 keeps it where it sat on the unzoomed screen, so
    /// a click in the corner does not yank that corner into the middle of the zoom.
    static func pointerAim(
        at pointer: CGPoint,
        in size: CGSize,
        magnification: Double,
        boundsBias: Double
    ) -> CGPoint {
        let bias = min(max(boundsBias, 0), 1)
        guard bias > 0, size.width > 1, size.height > 1 else { return pointer }
        let normalized = CGPoint(x: pointer.x / size.width, y: pointer.y / size.height)
        let half = 1 / (2 * max(magnification, 1))
        let span = 1 - 2 * half
        let preserved = CGPoint(
            x: half + normalized.x * span,
            y: half + normalized.y * span
        )
        return CGPoint(
            x: (normalized.x + (preserved.x - normalized.x) * bias) * size.width,
            y: (normalized.y + (preserved.y - normalized.y) * bias) * size.height
        )
    }

    static func pointerPosition(at time: TimeInterval, in samples: [PointerSample]) -> CGPoint? {
        guard let index = TimeSortedLookup.lastIndex(atOrBefore: time, in: samples, key: \.time) else {
            return samples.first?.position
        }
        return samples[index].position
    }

    /// The camera at `time`, interpolated between steps.
    public func viewport(at time: TimeInterval) -> Viewport {
        guard !magnifications.isEmpty else {
            return Viewport(magnification: 1, centre: CGPoint(x: size.width / 2, y: size.height / 2))
        }
        let exact = max(time, 0) / MotionSpring.step
        let lower = min(Int(exact.rounded(.down)), magnifications.count - 1)
        let upper = min(lower + 1, magnifications.count - 1)
        let fraction = exact - Double(lower)

        return Viewport(
            magnification: magnifications[lower]
                + (magnifications[upper] - magnifications[lower]) * fraction,
            centre: CGPoint(
                x: centres[lower].x + (centres[upper].x - centres[lower].x) * fraction,
                y: centres[lower].y + (centres[upper].y - centres[lower].y) * fraction
            )
        )
    }

    /// The source rect to sample for a frame, kept inside the recorded area.
    public func sourceRect(at time: TimeInterval) -> CGRect {
        viewport(at: time).clampedSourceRect(in: size)
    }

    /// Whether the camera is moving at `time`, to a tolerance.
    ///
    /// What the motion-blur pass asks: a still camera needs no supersampling, and skipping
    /// it where nothing moves is most of an export's time back.
    public func isMoving(at time: TimeInterval, tolerance: Double = 0.001) -> Bool {
        let before = viewport(at: max(time - MotionSpring.step, 0))
        let after = viewport(at: time + MotionSpring.step)
        if abs(after.magnification - before.magnification) > tolerance {
            return true
        }
        let moved = hypot(after.centre.x - before.centre.x, after.centre.y - before.centre.y)
        return moved > tolerance * max(size.width, 1)
    }
}

/// How an export supersamples a moving camera (docs/09 U3.3).
///
/// Motion blur is the reason a Screen-Studio-class zoom looks like video rather than like a
/// slideshow that scales. Without it, a fast camera move strobes: each frame is a sharp
/// picture of a different place, and the eye reads the gaps.
///
/// The fix is to render several times within one output frame's shutter and average them,
/// which is expensive — so the plan is computed rather than fixed, and a still camera gets
/// one sample like any ordinary render.
public struct MotionBlurPlan: Sendable, Hashable {
    /// How many renders make one output frame.
    public var sampleCount: Int
    /// How much of the frame's duration the shutter is open for.
    ///
    /// Half is the film convention (a 180° shutter) and looks right; a fully open shutter
    /// smears, and a narrow one is barely blur at all.
    public var shutterFraction: Double

    public init(sampleCount: Int, shutterFraction: Double = 0.5) {
        self.sampleCount = max(sampleCount, 1)
        self.shutterFraction = min(max(shutterFraction, 0.05), 1)
    }

    public static let none = MotionBlurPlan(sampleCount: 1)

    public var isBlurring: Bool {
        sampleCount > 1
    }

    /// The offsets within a frame to render at, in seconds.
    public func offsets(frameDuration: TimeInterval) -> [TimeInterval] {
        guard sampleCount > 1 else { return [0] }
        let shutter = frameDuration * shutterFraction
        return (0 ..< sampleCount).map { index in
            // Centred on the frame's own time, so the blur is symmetric about it rather
            // than dragging the picture forward.
            shutter * (Double(index) / Double(sampleCount - 1) - 0.5)
        }
    }

    /// The plan for a frame, given whether the camera is moving and how hard to smear
    /// (CleanShot §14.5). Intensity 0.5 is four samples at a 180° shutter — the look the
    /// studio shipped with before the slider existed.
    public static func plan(isMoving: Bool, intensity: Double = 0.5) -> MotionBlurPlan {
        let amount = min(max(intensity, 0), 1)
        guard isMoving, amount > 0.02 else { return .none }
        let samples = max(2, Int((amount * 8).rounded()))
        return MotionBlurPlan(sampleCount: samples, shutterFraction: 0.25 + amount * 0.35)
    }
}
