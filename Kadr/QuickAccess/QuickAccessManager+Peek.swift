import AppKit
import SettingsKit

/// Peek tab: hide the cards, leave a pill in the same corner (docs/03 §2).
///
/// Squashing each card to a sliver looked broken and was not clickable as a restore.
/// One tab owns expand and dismiss-all; the card panels stay alive off-screen so coming
/// back is a show, not a rebuild.
@MainActor
extension QuickAccessManager {
    /// Collapses every card to the peek tab, or restores them.
    ///
    /// Called when an editor window opens over the cards, or when the user flicks the
    /// stack toward the screen edge. Peeking rather than destroying the panels because
    /// hide-and-restore of the *items* is a race — the tab is always present, so there
    /// is no moment to get wrong. Clicking the tab expands even while the editor is still
    /// open; a new capture expands on its own so the new card is seen.
    func setPeeking(_ peeking: Bool) {
        if peeking, panels.isEmpty {
            return
        }
        guard isPeeking != peeking else { return }
        isPeeking = peeking
        if peeking {
            watchForEditorExit()
        } else {
            stopWatchingForEditorExit()
        }
        restack()
    }

    var isPeekTabVisible: Bool {
        peekPanel?.isVisible == true
    }

    func hidePeekTab() {
        peekPanel?.hide()
    }

    func teardownPeekTab() {
        peekPanel?.teardown()
        peekPanel = nil
    }

    func layoutPeekTab(on screen: NSScreen) {
        for entry in panels {
            entry.panel.hideForPeek()
        }

        let width = CGFloat(settings.overlayCardWidth)
        let height = QuickAccessPeekTabView.pillHeight
        let area = screen.visibleFrame
        let origin = CGPoint(
            x: settings.overlayCorner.isLeading
                ? area.minX + Self.screenMargin
                : area.maxX - width - Self.screenMargin,
            y: settings.overlayCorner.isBottom
                ? area.minY + Self.screenMargin
                : area.maxY - height - Self.screenMargin
        )
        let title = OverlayPeekCopy.title(
            count: panels.count,
            hasVideo: panels.contains { $0.item.isVideo }
        )
        let panel = peekPanelIfNeeded()
        panel.update(
            title: title,
            corner: settings.overlayCorner,
            size: CGSize(width: width, height: height)
        )
        panel.show(at: origin)
    }

    func peekPanelIfNeeded() -> QuickAccessPeekPanel {
        if let peekPanel {
            return peekPanel
        }
        let panel = QuickAccessPeekPanel(
            width: CGFloat(settings.overlayCardWidth),
            corner: settings.overlayCorner,
            title: "",
            onExpand: { [weak self] in self?.setPeeking(false) },
            onDismissAll: { [weak self] in self?.dismissAll() }
        )
        peekPanel = panel
        return panel
    }

    /// Restores the cards when the editor process goes away.
    ///
    /// The editor is a separate app that exits with its last window, so its termination is
    /// the signal that the user is done with it — and it is a notification rather than a
    /// poll, so a peeking agent costs nothing while it waits (CLAUDE.md rule 2). Clicking
    /// the tab also expands, so this is a convenience rather than the only way back.
    func watchForEditorExit() {
        guard editorExitObserver == nil else { return }
        editorExitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let key = NSWorkspace.applicationUserInfoKey
            guard let application = notification.userInfo?[key] as? NSRunningApplication,
                  application.bundleIdentifier == Self.editorBundleIdentifier
            else {
                return
            }
            MainActor.assumeIsolated {
                self?.setPeeking(false)
            }
        }
    }

    func stopWatchingForEditorExit() {
        guard let editorExitObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(editorExitObserver)
        self.editorExitObserver = nil
    }
}
