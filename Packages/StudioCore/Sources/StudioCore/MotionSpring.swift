import CoreGraphics
import Foundation

/// A critically damped spring, integrated at a fixed rate (docs/09 U3.2).
///
/// One spring, shared by the cursor and the camera, and that is the whole point. Two
/// separately-tuned smoothers make the pointer and the zoom settle at different moments,
/// which reads as the camera chasing the cursor — the exact thing a smooth recording is
/// supposed to avoid. Sharing the constant makes them arrive together by construction.
///
/// Critically damped rather than under-damped: overshoot on a cursor looks like the pointer
/// sliding past what it clicked, which is worse than being slightly late.
///
/// Integrated at a fixed step rather than per output frame, because otherwise the smoothing
/// depends on the export's frame rate — a 30 fps and a 60 fps render of the same edit would
/// move differently, and a preview would match neither.
public struct MotionSpring: Sendable, Hashable {
    /// How quickly the spring converges. Higher is snappier and less smooth.
    ///
    /// Around twelve is the value that reads as "deliberate": fast enough that a click
    /// lands where the user pointed, slow enough to take the jitter out of a hand-moved
    /// pointer.
    public var stiffness: Double

    public init(stiffness: Double = 12) {
        self.stiffness = max(stiffness, 0.01)
    }

    /// The step the integrator uses, in seconds.
    ///
    /// 240 Hz: fine enough that the result is indistinguishable from an exact solution at
    /// any output frame rate, coarse enough that a ten-minute recording integrates in
    /// milliseconds.
    public static let step: TimeInterval = 1.0 / 240

    /// The spring's position after `duration`, starting from `position` and chasing
    /// `target`.
    ///
    /// The closed form for a critically damped spring released from rest, which is exact
    /// and needs no integration at all for a constant target. The integrator below is for
    /// a target that moves.
    public func settled(from position: Double, to target: Double, over duration: TimeInterval) -> Double {
        guard duration > 0 else { return position }
        let decay = exp(-stiffness * duration)
        return target + (position - target) * decay
    }

    /// Advances one step towards a target.
    public func advance(_ position: Double, towards target: Double, by step: TimeInterval) -> Double {
        settled(from: position, to: target, over: step)
    }

    /// The same, for a point.
    public func advance(_ position: CGPoint, towards target: CGPoint, by step: TimeInterval) -> CGPoint {
        CGPoint(
            x: advance(position.x, towards: target.x, by: step),
            y: advance(position.y, towards: target.y, by: step)
        )
    }
}

/// Runs a spring over a series of targets, at a fixed rate (docs/09 U3.2, U3.3).
///
/// Shared by the cursor reconstruction and the camera timeline so that "smoothed" means the
/// same thing to both. Sampling the result is separate from producing it, which is what
/// lets a preview at 30 fps and an export at 60 fps agree exactly: they are reading the
/// same integration at different points, not integrating differently.
public struct SpringIntegrator: Sendable {
    public var spring: MotionSpring

    public init(spring: MotionSpring = MotionSpring()) {
        self.spring = spring
    }

    /// The smoothed path through `targets`, sampled every `MotionSpring.step`.
    ///
    /// - Parameters:
    ///   - targets: where the thing being smoothed wants to be, over time. Must be sorted.
    ///   - duration: how long to integrate for.
    /// - Returns: positions at fixed intervals from zero.
    public func integrate(
        targets: [(time: TimeInterval, value: CGPoint)],
        duration: TimeInterval
    ) -> [CGPoint] {
        guard !targets.isEmpty, duration > 0 else { return [] }

        var result: [CGPoint] = []
        result.reserveCapacity(Int(duration / MotionSpring.step) + 1)

        var position = targets[0].value
        var index = 0
        var time: TimeInterval = 0

        while time <= duration {
            // Walk the targets forward to the last one at or before now. A target list is
            // sorted, so this is a scan rather than a search per step.
            while index + 1 < targets.count, targets[index + 1].time <= time {
                index += 1
            }
            position = spring.advance(position, towards: targets[index].value, by: MotionSpring.step)
            result.append(position)
            time += MotionSpring.step
        }
        return result
    }

    /// The value at `time` from an integration, interpolated between steps.
    ///
    /// Linear between samples rather than nearest: at 240 Hz the difference is invisible,
    /// and rounding to a step would make a 60 fps export judder every fourth frame.
    public static func sample(_ path: [CGPoint], at time: TimeInterval) -> CGPoint? {
        guard !path.isEmpty else { return nil }
        guard time > 0 else { return path[0] }

        let exact = time / MotionSpring.step
        let lower = Int(exact.rounded(.down))
        guard lower < path.count - 1 else { return path[path.count - 1] }

        let fraction = exact - Double(lower)
        let first = path[lower]
        let second = path[lower + 1]
        return CGPoint(
            x: first.x + (second.x - first.x) * fraction,
            y: first.y + (second.y - first.y) * fraction
        )
    }
}
