import AppKit
import OverlayKit
import SettingsKit
import Shared
import SwiftUI

/// A floating thumbnail card (docs/03 §2).
///
/// Focus is the delicate part. The card must never take key status just by appearing —
/// the frontmost app keeps its cursor and its focus ring — but ⌫ has to reach the card
/// once the user is interacting with it. `becomesKeyOnlyIfNeeded` gives exactly that:
/// showing the panel steals nothing, clicking it hands it the keyboard.
@MainActor
final class QuickAccessPanel: NonActivatingPanel {
    private let hostingView: NSHostingView<QuickAccessCardView>

    init(item: QuickAccessItem, settings: AppSettings, actions: QuickAccessCardActions) {
        let width = CGFloat(settings.overlayCardWidth)
        let height = QuickAccessCardView.height(forWidth: width, item: item)

        hostingView = NSHostingView(rootView: QuickAccessCardView(
            item: item,
            actions: actions,
            width: width
        ))

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Floating, not screen-saver level: the card sits above ordinary windows but
        // below the selection overlay, which must cover everything.
        configureAsOverlay(level: .floating)
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        contentView = hostingView
    }

    /// Cards are ordered in without ever becoming key (docs/03 §2 accept list).
    func present(at origin: CGPoint) {
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    func dismiss() {
        contentView = nil
        orderOut(nil)
        close()
    }

    /// Applies the stacking transform: cards behind the front one shrink and fade.
    func setStackDepth(_ depth: Int, origin: CGPoint) {
        setFrameOrigin(origin)
        alphaValue = depth == 0 ? 1 : max(0.35, 1 - CGFloat(depth) * 0.18)
    }
}
