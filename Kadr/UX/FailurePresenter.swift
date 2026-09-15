import AppKit
import OverlayKit
import SwiftUI

/// A non-modal failure banner on the active screen (docs/16 APP-7).
///
/// Used for URL-scheme, login-item, relaunch and CLI-uninstall failures that must not
/// steal key focus from the app the user was in. Cancellation is ignored — the banner
/// stays until dismissed.
@MainActor
enum FailurePresenter {
    private static var panel: NonActivatingPanel?
    private static var hosting: NSHostingView<FeedbackBanner>?

    static func present(_ status: FeedbackStatus) {
        dismiss()
        FeedbackAnnouncement.post(status.message)

        let hosting = NSHostingView(rootView: FeedbackBanner(status: status, onDismiss: { dismiss() }))
        hosting.sizingOptions = .intrinsicContentSize
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let screen = ActiveScreen.resolve() ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 28
        )
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: origin, size: size),
            level: .statusBar
        )
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        CaptureExclusionRegistry.shared.register(panel)
        panel.orderFrontRegardless()
        Self.panel = panel
        Self.hosting = hosting
    }

    static func present(message: String) {
        present(FeedbackStatus(kind: .error, message: message))
    }

    static func dismiss() {
        guard let panel else { return }
        CaptureExclusionRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        Self.panel = nil
        hosting = nil
    }
}
