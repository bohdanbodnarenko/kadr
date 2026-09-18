import Foundation

/// How far to scroll per step, and how to deliver it (docs/03 §1.6, docs/04 §4.4).
///
/// Two rules, both learned from what a stitched page looks like when they are broken:
///
/// * **A step never moves more than part of a frame.** The stitcher finds where the new
///   frame overlaps the last one; a step as tall as the region leaves nothing to match on,
///   and the seam becomes a guess — a repeated band, or a missing one.
/// * **A step is a glide, not a flick.** One large wheel event reads to many apps as a
///   momentum scroll: the page keeps travelling after the event, past where the next frame
///   was grabbed, and lazily-loaded content arrives mid-flight. Several small pulses a
///   frame apart move the same distance with the page under control the whole way.
///
/// Pure arithmetic, so both rules are tested rather than tuned by eye.
public enum AutoScrollPlan: Sendable {
    /// The most of a frame a single step may consume. The rest is the stitcher's evidence.
    public static let maximumStepFraction = 0.6
    /// Small regions still have to make progress, so this is the floor.
    public static let minimumStepPoints = 40
    /// No single wheel event goes further than this, whatever the step is.
    public static let maximumPulsePoints = 40
    /// One display frame at 60 Hz between pulses.
    public static let pulseGapMilliseconds = 16

    /// The step to use for a region this tall (or, scrolling sideways, this wide).
    ///
    /// - Parameters:
    ///   - requested: what the user asked for in Settings.
    ///   - regionPoints: the captured region along the scrolling axis, in points.
    public static func stepPoints(requested: Int, regionPoints: Int) -> Int {
        // Never zero: a step of nothing would post events that move nothing, and the page
        // would look settled on the first frame.
        let ceiling = max(Int((Double(max(regionPoints, 1)) * maximumStepFraction).rounded(.down)), 1)
        // The floor gives way to the ceiling on a region too short to hold both, because
        // overlap is what makes a stitch possible and speed is only what makes it quick.
        let floor = min(minimumStepPoints, ceiling)
        return min(max(requested, floor), ceiling)
    }

    /// One step, split into pulses that sum to exactly `step`.
    ///
    /// Equal-sized where the arithmetic allows; the remainder is spread one point at a time
    /// across the first pulses rather than left as a short one at the end, so the page moves
    /// at a steady rate for the whole step.
    public static func pulses(forStep step: Int) -> [Int] {
        guard step > 0 else { return [] }
        let count = Int((Double(step) / Double(maximumPulsePoints)).rounded(.up))
        let base = step / count
        let remainder = step % count
        return (0 ..< count).map { index in
            base + (index < remainder ? 1 : 0)
        }
    }
}
