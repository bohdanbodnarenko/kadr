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
    /// Called when an editor window opens over the cards, or when the user flicks the stack
    /// toward the screen edge. Clicking the tab expands even while the editor is still open;
    /// a new capture expands on its own so the new card is seen.
    func setPeeking(_ peeking: Bool) {
        if peeking, items.isEmpty {
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
