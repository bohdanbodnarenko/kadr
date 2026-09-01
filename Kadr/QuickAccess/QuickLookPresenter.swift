import AppKit
import os
import QuickLookUI
import Shared

/// Space, over a card, to look at the capture properly.
///
/// A thumbnail 150 points wide is enough to recognise a capture and not enough to check
/// one. The alternative was opening the editor, which is a separate application, a launch,
/// and a document — far too much ceremony for "did I catch the whole dialog?". Space is
/// what Finder trained everybody to press, and it is the fastest way out of the card.
///
/// Beyond docs/03 §2, which does not mention Quick Look; noted here rather than invented
/// silently (CLAUDE.md rule 7).
///
/// Two things make this awkward from an agent. Quick Look's panel belongs to whichever
/// application is active, so a background agent has to activate to get it — that is a real
/// focus change, and it is why this is on an explicit key press and nothing else. And the
/// stack sits above every ordinary window, so it would cover the panel it just opened;
/// hence the collapse to the peek tab while it is up, and the expansion when it closes.
@MainActor
final class QuickLookPresenter: NSObject {
    private var url: NSURL?
    private let logger = KadrLog.logger(.overlay)
    /// Tucks the cards away while the panel is up, and brings them back after.
    private let setPeeking: (Bool) -> Void

    init(setPeeking: @escaping (Bool) -> Void) {
        self.setPeeking = setPeeking
        super.init()
    }

    static var isShowing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    func show(_ fileURL: URL) {
        guard let panel = QLPreviewPanel.shared() else {
            logger.error("Quick Look is unavailable")
            return
        }
        url = fileURL as NSURL

        // Before ordering the panel in, not after: the panel opens unfocused otherwise, and
        // an unfocused Quick Look will not start playing a recording until it is clicked.
        NSApp.activate()

        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        setPeeking(true)

        if panel.isVisible {
            panel.refreshCurrentPreviewItem()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }

        // Asked for again on the next pass through the run loop. Activation is asynchronous,
        // so a `makeKey` issued in the same turn as `activate()` can be dropped on the floor
        // while the window server is still deciding who is frontmost — leaving the panel on
        // screen and not accepting keys.
        Task { @MainActor in
            guard self.url != nil else { return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Closes the panel if it is up. Returns whether there was anything to close.
    @discardableResult
    func dismiss() -> Bool {
        guard Self.isShowing, let panel = QLPreviewPanel.shared() else {
            url = nil
            return false
        }
        panel.orderOut(nil)
        url = nil
        setPeeking(false)
        return true
    }
}

// The implicitly unwrapped optionals are `QLPreviewPanelDataSource`'s own: the protocol is
// declared in Objective-C without nullability annotations, so these are the signatures that
// satisfy it. Narrowing them here would not conform.
// swiftlint:disable implicitly_unwrapped_optional
extension QuickLookPresenter: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { url }
    }

    /// Quick Look closed itself — its own close button, or ⌘W, or losing focus.
    ///
    /// Without this the cards would stay tucked in the peek tab after the panel the peek
    /// was making room for had gone.
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            url = nil
            setPeeking(false)
        }
    }
}

// swiftlint:enable implicitly_unwrapped_optional
