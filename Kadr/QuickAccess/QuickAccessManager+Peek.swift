import AppKit
import SettingsKit

/// Peek tab: tuck the cards away, leave a pill in the same corner (docs/03 §2).
///
/// Squashing each card to a sliver looked broken and was not clickable as a restore. One
/// tab owns expand and dismiss-all.
///
/// Collapsing is now a flag rather than a piece of window management. The stack and the
/// pill are both mounted in the same panel the whole time, and this slides one out as the
/// other slides in — so there is no ordering-out to race a capture that arrives mid-collapse,
/// and the transition is something the user can actually see happen.
@MainActor
extension QuickAccessManager {
    /// Collapses every card to the peek tab, or restores them.
    ///
    /// The user's own gesture, now: a flick of the stack toward the screen edge, or Quick
    /// Look taking the screen. Opening the editor used to collapse the stack too, and an
    /// observer on the editor's termination put it back — but hiding captures that have
    /// nothing to do with the edit, and leaving a pill to deal with afterwards, was worse
    /// than letting the edited card retire and the rest stay put.
    ///
    /// Clicking the tab expands; a new capture expands on its own so the new card is seen.
    func setPeeking(_ peeking: Bool) {
        if peeking, items.isEmpty {
            return
        }
        guard isPeeking != peeking else { return }
        isPeeking = peeking
        restack()
    }
}
