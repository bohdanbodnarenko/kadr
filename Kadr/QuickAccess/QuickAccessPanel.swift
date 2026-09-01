import AppKit
import OverlayKit
import SettingsKit
import Shared
import SwiftUI

/// First click on a non-activating overlay must count (docs/04 §5).
///
/// Not generic: a `NSHostingView<Content>` subclass crashes Swift 6.3's Release inliner
/// in the synthesized `deinit` (`EarlyPerfInliner` / `OverlayHostingViewCfD`). Erasing to
/// `AnyView` keeps the first-click override without that specialization.
final class OverlayHostingView: NSHostingView<AnyView> {
    init(rootView: some View) {
        super.init(rootView: AnyView(rootView))
    }

    @available(*, unavailable)
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OverlayHostingView is created in code only")
    }

    func setRootView(_ view: some View) {
        rootView = AnyView(view)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// A floating thumbnail card (docs/03 §2).
///
/// Focus is the delicate part. The card must never take key status just by appearing —
/// the frontmost app keeps its cursor and its focus ring — but ⌫ has to reach the card
/// once the user is interacting with it. `becomesKeyOnlyIfNeeded` gives exactly that:
/// showing the panel steals nothing, clicking it hands it the keyboard.
@MainActor
final class QuickAccessPanel: NonActivatingPanel {
    private let hostingView: OverlayHostingView
    private var cardActions: QuickAccessCardActions
    private let settings: AppSettings

    init(item: QuickAccessItem, settings: AppSettings, actions: QuickAccessCardActions) {
        self.settings = settings
        cardActions = actions
        let width = CGFloat(settings.overlayCardWidth)
        let height = QuickAccessCardView.height(forWidth: width, item: item)

        hostingView = OverlayHostingView(rootView: QuickAccessCardView(
            item: item,
            actions: actions,
            width: width,
            layout: settings.cardLayout
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
        // Kept out of Kadr's own captures (docs/09 U2.1).
        CaptureExclusionRegistry.shared.register(self)
    }

    func dismiss() {
        CaptureExclusionRegistry.shared.unregister(self)
        contentView = nil
        orderOut(nil)
        close()
    }

    /// Parks the card while the peek tab is showing. The panel stays alive so restore
    /// is a show, not a rebuild (docs/03 §2).
    func hideForPeek() {
        guard isVisible else { return }
        orderOut(nil)
    }

    func revealFromPeek() {
        guard !isVisible else { return }
        orderFrontRegardless()
        CaptureExclusionRegistry.shared.register(self)
    }

    // MARK: - Pass-through (docs/09 U2.1)

    /// The card does not use `InteractiveRegionTracker`, and taking it out is what brought
    /// hover back.
    ///
    /// The tracker exists for a panel with *sparse* controls: it publishes the few rects
    /// that take clicks and flips `ignoresMouseEvents` so the rest of a big transparent
    /// window lets the app underneath through. This card published its entire frame, so the
    /// mechanism had nothing to pass through — a window already ignores everything outside
    /// itself — and one real effect: while the pointer was anywhere else, the card sat with
    /// `ignoresMouseEvents = true`.
    ///
    /// A window that ignores mouse events receives no `mouseEntered` and no `mouseMoved`, so
    /// SwiftUI's `onHover` could never fire from inside it. The only thing that could turn
    /// the card back on was a *global* monitor, which sees events dispatched to other
    /// applications — and the moment the card became interactive it started taking those
    /// events itself, so the signal that was meant to maintain hover went quiet exactly when
    /// hover was needed. Hence: no hover, ever, and clicks that sometimes did not land.
    ///
    /// The pass-through machinery is still right for the overlays it was written for. It was
    /// wrong here.
    /// Set while the card is deliberately inert — during a capture, say.
    var isIgnoringClicks = false {
        didSet { ignoresMouseEvents = isIgnoringClicks }
    }

    func setCardSize(width: CGFloat, height: CGFloat) {
        setFrame(CGRect(x: frame.minX, y: frame.minY, width: width, height: height), display: true)
    }

    /// Rebuilds the card's content after its item changed (docs/09 U2.4).
    ///
    /// The hosting view holds a value, not a reference, so a card whose item has gained a
    /// savings badge needs a new root rather than a redraw.
    func refresh(item: QuickAccessItem, settings: AppSettings, actions: QuickAccessCardActions) {
        cardActions = actions
        hostingView.setRootView(QuickAccessCardView(
            item: item,
            actions: actions,
            width: CGFloat(settings.overlayCardWidth),
            layout: settings.cardLayout
        ))
    }

    /// Applies the stacking transform: cards behind the front one shrink and fade.
    func setStackDepth(_ depth: Int, origin: CGPoint) {
        setFrameOrigin(origin)
        alphaValue = depth == 0 ? 1 : max(0.35, 1 - CGFloat(depth) * 0.18)
    }

    override func scrollWheel(with event: NSEvent) {
        switch OverlaySwipe.from(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            corner: settings.overlayCorner
        ) {
        case .dismiss:
            cardActions.dismiss()
        case .peek:
            cardActions.peek()
        case nil:
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            cardActions.delete()
        case 53:
            cardActions.dismiss()
        default:
            super.keyDown(with: event)
        }
    }
}
