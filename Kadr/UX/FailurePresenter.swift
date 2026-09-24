import AppKit
import os
import OverlayKit
import SwiftUI

/// The one way a failure in a user-initiated path reaches the user (docs/16 APP-7,
/// docs/17 §5 theme 2).
///
/// A non-modal banner on the active screen, for failures with nowhere better to show:
/// URL-scheme, login-item, relaunch and CLI-uninstall failures, a capture that could not
/// be written with no card up, or an Undo offer once the last card has gone. It must not
/// steal key focus from the app the user was in. Failures and warnings stay until
/// dismissed; completions (an Undo) take themselves away.
///
/// The rule this enforces: `logger.error` in a path the user started is half a report.
/// Use `report(_:logger:)`, which logs *and* shows, so the log and the user hear the same
/// thing.
@MainActor
enum FailurePresenter {
    private static var panel: NonActivatingPanel?

    static func present(_ status: FeedbackStatus) {
        dismiss()
        FeedbackAnnouncement.post(status.message)

        // `OverlayHostingView` for its first-mouse: Kadr is rarely active when this is up,
        // and a Retry that needs one click to focus and another to press is broken.
        let hosting = OverlayHostingView(rootView: FeedbackBanner(status: status, onDismiss: { dismiss() }))
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
    }

    static func present(message: String) {
        present(FeedbackStatus(kind: .error, message: message))
    }

    /// Logs a failure and shows it, in one call.
    static func report(
        _ message: String,
        detail: String? = nil,
        logger: Logger,
        retryTitle: String? = nil,
        retry: (() -> Void)? = nil
    ) {
        logger.error("\(message, privacy: .public): \(detail ?? "-", privacy: .public)")
        present(.failure(message, retryTitle: retryTitle, retry: retry))
    }

    /// Whether a banner is up, for tests.
    static var isPresenting: Bool {
        panel != nil
    }

    static func dismiss() {
        guard let panel else { return }
        CaptureExclusionRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        Self.panel = nil
    }
}
