import Foundation

/// Pure mapping for the inspector scrub track (docs/09 U1.5).
///
/// Kept off the view so the detent and the absolute-position mapping can be tested
/// without standing up SwiftUI. Dragging is absolute: the pointer's x on the track *is*
/// the value, the way a native slider works, not a relative nudge from wherever the
/// press started.
enum InspectorSliderMapping {
    /// Sticky zone around zero, in points. Small enough that nearby values stay
    /// reachable, large enough that landing on zero is something you feel.
    static let detentRadius: Double = 3

    static func progress(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span.isFinite, span > 0, value.isFinite else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// Where zero sits on a signed range, or nil when the range does not cross it.
    static func zeroProgress(in range: ClosedRange<Double>) -> Double? {
        guard range.lowerBound.isFinite,
              range.upperBound.isFinite,
              range.lowerBound < 0,
              range.upperBound > 0
        else { return nil }
        return (0 - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// The stored value for a pointer x on a track of `width`.
    ///
    /// Signed ranges get a soft zero detent: a few points land exactly on 0, and each
    /// side is remapped around that zone so values just off zero are not swallowed.
    static func value(
        at locationX: Double,
        width: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard width > 0,
              range.lowerBound.isFinite,
              range.upperBound.isFinite
        else { return range.lowerBound }

        if let mapped = detentValue(at: locationX, width: width, range: range) {
            return mapped
        }

        let progress = min(max(locationX / width, 0), 1)
        return range.lowerBound + progress * (range.upperBound - range.lowerBound)
    }

    private static func detentValue(
        at locationX: Double,
        width: Double,
        range: ClosedRange<Double>
    ) -> Double? {
        guard let zeroProgress = zeroProgress(in: range) else { return nil }
        let zeroX = zeroProgress * width
        let leftSpan = zeroX - detentRadius
        let rightSpan = width - zeroX - detentRadius
        guard leftSpan > 0, rightSpan > 0 else { return nil }

        if abs(locationX - zeroX) <= detentRadius {
            return 0
        }
        if locationX < zeroX {
            let progress = min(max(locationX / leftSpan, 0), 1)
            return range.lowerBound * (1 - progress)
        }
        let progress = min(max((locationX - zeroX - detentRadius) / rightSpan, 0), 1)
        return range.upperBound * progress
    }
}
