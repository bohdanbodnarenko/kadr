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
        dismissTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.autoDismissIfIdle(item)
        }
    }

    /// Dismisses a card whose timer has fired, or waits if the user is still on it.
    ///
    /// Hover and drag retry in a couple of seconds, matching Screendrop: glancing at a
    /// card must not cancel auto-close forever, or a timeout setting does nothing the
    /// moment the pointer crosses the thumbnail. Engagement is permanent.
    func autoDismissIfIdle(_ item: QuickAccessItem) {
        guard panels.contains(where: { $0.item.id == item.id }) else { return }
        guard !engagedItems.contains(item.id) else { return }
        guard isIdleForAutoDismiss(item) else {
            dismissTasks[item.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.idleRetrySeconds))
                guard !Task.isCancelled else { return }
                self?.autoDismissIfIdle(item)
            }
            return
        }
        dismiss(item)
    }

    /// Whether a timeout may take this card now. Engaged cards are not idle.
    ///
    /// Neither is one with its first-run tip open: taking the card away from under its own
    /// explanation is the one outcome that teaches nothing. Paused rather than engaged —
    /// engagement is permanent by design, and a first capture should still tidy itself away
    /// once the user has read the tip and moved on.
    func isIdleForAutoDismiss(_ item: QuickAccessItem) -> Bool {
        hoveredItemID != item.id && draggingItemID != item.id && !isShowingCoachTip(for: item)
    }

    /// The user opened this capture (editor / studio / trim), so it stops being disposable.
    func noteEngagement(with item: QuickAccessItem) {
        guard !engagedItems.contains(item.id) else { return }
        engagedItems.insert(item.id)
        dismissTasks.removeValue(forKey: item.id)?.cancel()
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
            hoveredItemID = item.id
            startHoverKeyMonitorIfNeeded()
        } else if hoveredItemID == item.id {
            hoveredItemID = nil
            stopHoverKeyMonitorIfIdle()
        }
    }

    func beginDrag(for item: QuickAccessItem) {
        draggingItemID = item.id
    }

    func endDrag(for item: QuickAccessItem) {
        if draggingItemID == item.id {
            draggingItemID = nil
        }
    }

    func startHoverKeyMonitorIfNeeded() {
        guard hoverKeyMonitor == nil else { return }
        hoverKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            MainActor.assumeIsolated {
                _ = self?.handleHoverKey(keyCode)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let consumed = MainActor.assumeIsolated {
                self?.handleHoverKey(keyCode) ?? false
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

    /// ⌫ deletes, Esc hides. Only while a card is hovered, so the front app keeps its
    /// keys the rest of the time (docs/03 §2).
    func handleHoverKey(_ keyCode: UInt16) -> Bool {
        guard let hoveredItemID,
              let item = panels.first(where: { $0.item.id == hoveredItemID })?.item
        else {
            return false
        }
        switch keyCode {
        case 51, 117:
            delete(item)
            return true
        case 53:
            dismiss(item)
            return true
        default:
            return false
        }
    }
}
