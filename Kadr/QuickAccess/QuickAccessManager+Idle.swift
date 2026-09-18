import AppKit
import os
import SettingsKit

/// Auto-dismiss, hover pause, and the keys that work while a card is under the pointer.
///
/// Hover pauses the timer; it does not claim the card. Opening the editor (or studio /
/// trim) is the high-intent action that keeps a card until the user hides it themselves
/// (docs/03 §2).
@MainActor
extension QuickAccessManager {
    static let idleRetrySeconds: TimeInterval = 2

    func scheduleAutoDismiss(for item: QuickAccessItem) {
        let seconds = settings.overlayTimeout.seconds
        guard seconds > 0, !engagedItems.contains(item.id) else { return }
        dismissDeadlines[item.id] = .now + .seconds(seconds)
        armDismissal(for: item, after: TimeInterval(seconds))
    }

    private func armDismissal(for item: QuickAccessItem, after seconds: TimeInterval) {
        dismissTasks[item.id]?.cancel()
        dismissTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.autoDismissIfIdle(item)
        }
    }

    /// Dismisses a card whose timer has fired, or waits if the user is still on it.
    ///
    /// Hover and drag wait for the pointer to leave or the drag to end — `resumeAutoDismiss`
    /// re-arms the timer then, with a couple of seconds' grace: glancing at a card must
    /// not cancel auto-close forever, or a timeout setting does
    /// nothing the moment the pointer crosses the thumbnail. Nothing runs while the pointer
    /// rests on a card; this used to wake every two seconds to ask whether it still did.
    ///
    /// The first-run tip and a running action have no such event, so those still check
    /// back every couple of seconds — they are short, and rare. Engagement is permanent.
    func autoDismissIfIdle(_ item: QuickAccessItem) {
        dismissTasks.removeValue(forKey: item.id)
        guard items.contains(where: { $0.id == item.id }) else { return }
        guard !engagedItems.contains(item.id) else { return }
        guard isIdleForAutoDismiss(item) else {
            if !isHeldByPointer(item) {
                armDismissal(for: item, after: Self.idleRetrySeconds)
            }
            return
        }
        dismiss(item)
    }

    /// Hovered or being dragged: the two holds that announce their own end.
    private func isHeldByPointer(_ item: QuickAccessItem) -> Bool {
        hoveredItemID == item.id || draggingItemID == item.id
    }

    /// Stops the timer while the pointer holds a card.
    private func pauseAutoDismiss(for item: QuickAccessItem) {
        dismissTasks.removeValue(forKey: item.id)?.cancel()
    }

    /// Restarts the timer once nothing holds the card, with whatever was left of it — and
    /// never less than the grace period, so moving the pointer off does not snap the card
    /// away under it.
    private func resumeAutoDismiss(for item: QuickAccessItem) {
        guard let deadline = dismissDeadlines[item.id],
              !engagedItems.contains(item.id),
              !isHeldByPointer(item),
              let live = items.first(where: { $0.id == item.id })
        else {
            return
        }
        let remaining = ContinuousClock.now.duration(to: deadline)
        let seconds = Double(remaining.components.seconds)
            + Double(remaining.components.attoseconds) / 1e18
        armDismissal(for: live, after: max(seconds, Self.idleRetrySeconds))
    }

    /// Whether a timeout may take this card now. Engaged cards are not idle.
    ///
    /// Neither is one with its first-run tip open: taking the card away from under its own
    /// explanation is the one outcome that teaches nothing. Paused rather than engaged —
    /// engagement is permanent by design, and a first capture should still tidy itself away
    /// once the user has read the tip and moved on.
    func isIdleForAutoDismiss(_ item: QuickAccessItem) -> Bool {
        let live = items.first { $0.id == item.id } ?? item
        return hoveredItemID != live.id && draggingItemID != live.id && !isShowingCoachTip(for: live)
            && live.activity == nil
    }

    /// The user opened this capture (editor / studio / trim), so it stops being disposable.
    func noteEngagement(with item: QuickAccessItem) {
        guard !engagedItems.contains(item.id) else { return }
        engagedItems.insert(item.id)
        dismissTasks.removeValue(forKey: item.id)?.cancel()
        dismissDeadlines.removeValue(forKey: item.id)
        logger.info("Card engaged; auto-close cancelled")
    }

    func isEngaged(_ item: QuickAccessItem) -> Bool {
        engagedItems.contains(item.id)
    }

    func isHovered(_ item: QuickAccessItem) -> Bool {
        hoveredItemID == item.id
    }

    func setHovered(_ item: QuickAccessItem, hovering: Bool) {
        if hovering {
            let previous = hoveredItemID
            hoveredItemID = item.id
            startHoverKeyMonitorIfNeeded()
            pauseAutoDismiss(for: item)
            // The pointer moved straight from one card to another without an exit event.
            if let previous, previous != item.id, let left = items.first(where: { $0.id == previous }) {
                resumeAutoDismiss(for: left)
            }
        } else if hoveredItemID == item.id {
            hoveredItemID = nil
            stopHoverKeyMonitorIfIdle()
            resumeAutoDismiss(for: item)
        }
    }

    func beginDrag(for item: QuickAccessItem) {
        draggingItemID = item.id
        pauseAutoDismiss(for: item)
    }

    func endDrag(for item: QuickAccessItem) {
        if draggingItemID == item.id {
            draggingItemID = nil
            resumeAutoDismiss(for: item)
        }
    }

    func startHoverKeyMonitorIfNeeded() {
        guard hoverKeyMonitor == nil else { return }
        hoverKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                _ = self?.handleHoverKey(event, canStealCommandKeys: false)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                self?.handleHoverKey(event, canStealCommandKeys: true) ?? false
            }
            return consumed ? nil : event
        }
    }

    func stopHoverKeyMonitorIfIdle() {
        guard hoveredItemID == nil else { return }
        stopHoverKeyMonitor()
    }

    func stopHoverKeyMonitor() {
        if let hoverKeyMonitor {
            NSEvent.removeMonitor(hoverKeyMonitor)
            self.hoverKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    /// ⌫ deletes, Esc hides, Space looks. ⌘C / ⌘S / ⌘E / ⌘P / ⌘W copy, save, annotate,
    /// pin, and close, but only from the local monitor — a global one cannot swallow those
    /// keys, and doing the action *and* letting the front app handle them would be two
    /// saves for one press (docs/03 §2, CleanShot §6.2 / §22.2).
    func handleHoverKey(_ event: NSEvent, canStealCommandKeys: Bool) -> Bool {
        let keyCode = event.keyCode
        // Esc closes Quick Look before it closes anything else — the panel is what the user
        // is looking at, so it is what "escape" means while it is up. Handled before the
        // hover lookup, because opening Quick Look tucks the cards away and nothing is
        // hovered any more.
        if keyCode == 53, quickLook.dismiss() {
            return true
        }
        guard let hoveredItemID,
              let item = items.first(where: { $0.id == hoveredItemID })
        else {
            return false
        }
        if canStealCommandKeys, handleHoverCommandKey(event, item: item) {
            return true
        }
        switch keyCode {
        case 51, 117:
            delete(item)
            return true
        case 53:
            dismiss(item)
            return true
        case 49:
            // Looking at a capture is the user working with it, so the card stops being
            // disposable — the same rule as opening the editor.
            noteEngagement(with: item)
            quickLook.show(item.fileURL)
            return true
        case 36, 76:
            // Return / keypad Enter — save and close (CleanShot §6.2). Quick Look keeps
            // Return for itself while the panel is up.
            guard settings.overlayReturnSaves, !QuickLookPresenter.isShowing else { return false }
            save(item)
            return true
        default:
            return false
        }
    }

    /// Overlay action keys that would steal from the front app if a global monitor ran them.
    ///
    /// CleanShot §22.2: ⌘C copy, ⌘S save, ⌘E annotate (trim, for a recording), ⌘P pin,
    /// ⌘W close. Upload is out of scope.
    func handleHoverCommandKey(_ event: NSEvent, item: QuickAccessItem) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.shift),
              !event.modifierFlags.contains(.option)
        else {
            return false
        }
        switch event.keyCode {
        case 8:
            copy(item)
            return true
        case 1:
            save(item)
            return true
        case 14:
            if item.isVideo {
                trim(item)
            } else {
                annotate(item)
            }
            return true
        case 35:
            guard !item.isVideo else { return false }
            pin(item)
            return true
        case 13:
            dismiss(item)
            return true
        default:
            return false
        }
    }
}
