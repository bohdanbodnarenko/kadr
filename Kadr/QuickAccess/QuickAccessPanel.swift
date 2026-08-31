import AppKit
import OverlayKit
import SettingsKit
import Shared
import SwiftUI

/// First click on a non-activating overlay must count (docs/04 §5).
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
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
final class QuickAccessPanel: NonActivatingPanel, InteractivelyMasked {
    private let hostingView: OverlayHostingView<QuickAccessCardView>
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
        // Kept out of Kadr's own captures, and out of everyone's way except where it has
        // a control (docs/09 U2.1).
        CaptureExclusionRegistry.shared.register(self)
        InteractiveRegionTracker.shared.register(self)
    }

    func dismiss() {
        InteractiveRegionTracker.shared.unregister(self)
        CaptureExclusionRegistry.shared.unregister(self)
        contentView = nil
        orderOut(nil)
        close()
    }

    /// Parks the card while the peek tab is showing. The panel stays alive so restore
    /// is a show, not a rebuild (docs/03 §2).
    func hideForPeek() {
        guard isVisible else { return }
        InteractiveRegionTracker.shared.unregister(self)
        orderOut(nil)
    }

    func revealFromPeek() {
        guard !isVisible else { return }
        orderFrontRegardless()
        CaptureExclusionRegistry.shared.register(self)
        InteractiveRegionTracker.shared.register(self)
    }

    // MARK: - Pass-through (docs/09 U2.1)

    /// The card's own frame, because every part of a card is a control.
    var interactiveRegions: InteractiveRegions {
        guard !isIgnoringClicks else { return .none }
        return InteractiveRegions(rects: [frame])
    }

    var passesMouseThrough: Bool {
        get { ignoresMouseEvents }
        set { ignoresMouseEvents = newValue }
    }

    /// Set while the card is deliberately inert — during a capture, say.
    var isIgnoringClicks = false {
        didSet {
            InteractiveRegionTracker.shared.update(at: NSEvent.mouseLocation)
        }
    }

    func setCardSize(width: CGFloat, height: CGFloat) {
        setFrame(CGRect(x: frame.minX, y: frame.minY, width: width, height: height), display: true)
        InteractiveRegionTracker.shared.update(at: NSEvent.mouseLocation)
    }

    /// Rebuilds the card's content after its item changed (docs/09 U2.4).
    ///
    /// The hosting view holds a value, not a reference, so a card whose item has gained a
    /// savings badge needs a new root rather than a redraw.
    func refresh(item: QuickAccessItem, settings: AppSettings, actions: QuickAccessCardActions) {
        cardActions = actions
        hostingView.rootView = QuickAccessCardView(
            item: item,
            actions: actions,
            width: CGFloat(settings.overlayCardWidth),
            layout: settings.cardLayout
        )
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
