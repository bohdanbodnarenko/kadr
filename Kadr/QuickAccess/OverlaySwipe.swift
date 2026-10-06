import CoreGraphics
import SettingsKit

/// Trackpad flicks on a Quick Access card (docs/03 §2).
///
/// Horizontal toward the docked edge hides that card (the file stays). Vertical toward
/// the screen edge tucks the whole stack into the peek tab.
///
/// A swipe acts once it has travelled far enough, or on a fast flick that has at least
/// started to move. The old 6–8 pt thresholds let a resting finger's drift dismiss a card
/// (docs/18 OUT-16).
nonisolated enum OverlaySwipe: Equatable {
    case dismiss
    case peek

    /// Travel that commits a dismissal, in points.
    static let dismissDistance: CGFloat = 48
    /// Travel that commits a peek, in points.
    static let peekDistance: CGFloat = 32
    /// One event's travel that counts as a flick, in points.
    static let flickStep: CGFloat = 24
    /// The least total travel a flick still needs, so a single jolt is not a swipe.
    static let flickMinimum: CGFloat = 16

    static func from(
        deltaX: CGFloat,
        deltaY: CGFloat,
        corner: OverlayCorner,
        lastStep: CGSize = .zero
    ) -> OverlaySwipe? {
        if abs(deltaX) > abs(deltaY) {
            let outward: CGFloat = corner.isLeading ? -1 : 1
            let travel = deltaX * outward
            let flick = lastStep.width * outward >= flickStep && travel >= flickMinimum
            return travel >= dismissDistance || flick ? .dismiss : nil
        }
        let toward: CGFloat = corner.isBottom ? 1 : -1
        let travel = deltaY * toward
        let flick = lastStep.height * toward >= flickStep && travel >= flickMinimum
        return travel >= peekDistance || flick ? .peek : nil
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

    /// How far the card should sit from its place while the finger is still on it: the
    /// horizontal travel so far, until the gesture acts or ends. The card follows the
    /// finger, so a swipe that falls short visibly springs back (docs/18 OUT-16).
    var liveOffsetX: CGFloat {
        guard !hasFired, abs(deltaX) > abs(deltaY) else { return 0 }
        return deltaX
    }

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
        guard !hasFired, let swipe = OverlaySwipe.from(
            deltaX: self.deltaX,
            deltaY: self.deltaY,
            corner: corner,
            lastStep: CGSize(width: deltaX, height: deltaY)
        ) else {
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
