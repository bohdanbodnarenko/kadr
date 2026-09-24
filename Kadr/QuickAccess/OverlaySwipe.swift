import CoreGraphics
import SettingsKit

/// Trackpad flicks on a Quick Access card (docs/03 §2).
///
/// Horizontal toward the docked edge hides that card (the file stays). Vertical toward
/// the screen edge tucks the whole stack into the peek tab. Thresholds match the ones
/// that feel like a flick rather than a nudge.
nonisolated enum OverlaySwipe: Equatable {
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

/// One swipe, one action (docs/17 T-OUT-13).
///
/// Every scroll event used to be judged on its own, so one long swipe dismissed a card,
/// then the one that slid under the pointer, then the next; and a mouse-wheel notch, which
/// has no gesture at all, collapsed the stack. This accumulates a trackpad gesture from
/// `.began` to `.ended` and fires at most once for it. Wheels are ignored.
nonisolated struct OverlaySwipeTracker {
    private var deltaX: CGFloat = 0
    private var deltaY: CGFloat = 0
    private var hasFired = false

    enum Phase {
        case began
        case changed
        case ended
    }

    /// Feeds one event. Returns the swipe to act on, the first time the gesture makes one.
    mutating func feed(
        phase: Phase,
        deltaX: CGFloat,
        deltaY: CGFloat,
        isPrecise: Bool,
        corner: OverlayCorner
    ) -> OverlaySwipe? {
        guard isPrecise else { return nil }
        switch phase {
        case .began:
            self.deltaX = deltaX
            self.deltaY = deltaY
            hasFired = false
        case .changed:
            self.deltaX += deltaX
            self.deltaY += deltaY
        case .ended:
            reset()
            return nil
        }
        guard !hasFired, let swipe = OverlaySwipe.from(deltaX: self.deltaX, deltaY: self.deltaY, corner: corner) else {
            return nil
        }
        hasFired = true
        return swipe
    }

    mutating func reset() {
        deltaX = 0
        deltaY = 0
        hasFired = false
    }
}
