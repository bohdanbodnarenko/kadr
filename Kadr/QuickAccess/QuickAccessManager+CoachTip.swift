import AppKit
import SettingsKit
import Shared

/// The one-time explanation over the first capture card (docs/03 §2).
///
/// Its own file because it is the only part of the overlay about *teaching* rather than
/// about showing a capture — and because it has one rule worth stating alone: the tip pauses
/// auto-close while it is up and never claims the card permanently. Taking a card away from
/// under its own explanation teaches nothing; keeping the first one forever would be a
/// different surprise.
@MainActor
extension QuickAccessManager {
    /// Teaches the card, once, the first time there is one to point at (docs/03 §2).
    ///
    /// A card in the corner shows a picture and nothing about it says that hovering reveals
    /// the actions, that it can be dragged straight into Slack, or that double-clicking
    /// opens the editor. The commonest outcome for a first capture is somebody looking at
    /// it, failing to work out what it wants, and waiting for it to disappear.
    ///
    /// Not part of onboarding, which runs before the user has captured anything — the wrong
    /// moment to explain a card they have never seen.
    func presentCoachTipIfNeeded(over panel: QuickAccessPanel, item: QuickAccessItem) {
        guard !settings.hasSeenQuickAccessTip, coachTip == nil else { return }
        guard let anchor = panel.contentView else { return }

        let tip = QuickAccessCoachTip { [weak self] in
            self?.settings.hasSeenQuickAccessTip = true
            self?.coachTip = nil
        }
        coachTip = tip
        // After the card has been ordered in and laid out, so the popover has a frame to
        // point at rather than a zero rect in the corner of the screen.
        Task { @MainActor [weak self] in
            guard let self, coachTip === tip, panel.isVisible else { return }
            tip.show(relativeTo: anchor)
        }
    }

    /// Whether the first-run tip is currently pointing at this card.
    func isShowingCoachTip(for item: QuickAccessItem) -> Bool {
        coachTip != nil && panels.first?.item.id == item.id
    }

    // Closes the tip if it is pointing at a card that is going away.
    //
    // A popover anchored to a view whose window has closed is a popover left hanging in the
    // corner with nothing under it. Counted as seen either way: the user got the
    // explanation on screen, and showing it again on the next capture would be a tip that
    // nags.

    func dismissCoachTip(for item: QuickAccessItem) {
        guard coachTip != nil, panels.first?.item.id == item.id else { return }
        settings.hasSeenQuickAccessTip = true
        coachTip?.dismiss()
        coachTip = nil
    }
}
