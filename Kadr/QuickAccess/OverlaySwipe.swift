import CoreGraphics
import SettingsKit

/// Trackpad flicks on a Quick Access card (docs/03 §2).
///
/// Horizontal toward the docked edge hides that card (the file stays). Vertical toward
/// the screen edge tucks the whole stack into the peek tab. Thresholds match the ones
/// that feel like a flick rather than a nudge.
enum OverlaySwipe: Equatable {
    case dismiss
    case peek

    static func from(deltaX: CGFloat, deltaY: CGFloat, corner: OverlayCorner) -> OverlaySwipe? {
        if abs(deltaX) > abs(deltaY) {
            let outward: CGFloat = corner.isLeading ? -1 : 1
            return deltaX * outward > 8 ? .dismiss : nil
        }
        if corner.isBottom {
            return deltaY > 6 ? .peek : nil
        }
        return deltaY < -6 ? .peek : nil
    }
}
