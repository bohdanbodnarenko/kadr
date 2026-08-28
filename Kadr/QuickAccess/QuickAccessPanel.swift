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
final class QuickAccessPanel: NonActivatingPanel, InteractivelyMasked {
    private let hostingView: NSHostingView<QuickAccessCardView>

    /// How the card is showing itself (docs/09 U2.1).
    enum Presentation: Equatable {
        /// The whole card.
        case expanded
        /// A tab at the screen edge, out of the way of an editor window.
        case peeking
    }

    private(set) var presentation: Presentation = .expanded

    /// How wide the peek tab is. Enough to grab and to show a thumbnail sliver, narrow
    /// enough that it reads as parked rather than as a small card.
    static let peekWidth: CGFloat = 26

    init(item: QuickAccessItem, settings: AppSettings, actions: QuickAccessCardActions) {
        let width = CGFloat(settings.overlayCardWidth)
        let height = QuickAccessCardView.height(forWidth: width, item: item)

        hostingView = NSHostingView(rootView: QuickAccessCardView(
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

    // MARK: - Pass-through (docs/09 U2.1)

    /// The card's own frame, because every part of a card is a control.
    ///
    /// The rectangle a card occupies is nearly all thumbnail and buttons; what makes the
    /// pass-through worth having is that a *peeking* card is almost entirely out of the
    /// way, and that a card which has been asked to hide takes no clicks at all.
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

    // MARK: - Peek (docs/09 U2.1)

    /// Collapses the card to an edge tab, or restores it.
    ///
    /// Peeking rather than hiding, because hiding and showing again is a race: the card
    /// has to be put back exactly where it was, at exactly the right moment, and any
    /// mistake either loses the card or flashes it over the editor. A tab is always
    /// present, so there is no moment to get wrong — and it is still a target the user can
    /// click to bring the card back.
    func setPresentation(_ presentation: Presentation, edge: CGFloat, width: CGFloat, height: CGFloat) {
        self.presentation = presentation
        switch presentation {
        case .expanded:
            setFrame(CGRect(x: frame.minX, y: frame.minY, width: width, height: height), display: true)
        case .peeking:
            setFrame(
                CGRect(x: edge - Self.peekWidth, y: frame.minY, width: Self.peekWidth, height: height),
                display: true
            )
        }
        InteractiveRegionTracker.shared.update(at: NSEvent.mouseLocation)
    }

    /// Rebuilds the card's content after its item changed (docs/09 U2.4).
    ///
    /// The hosting view holds a value, not a reference, so a card whose item has gained a
    /// savings badge needs a new root rather than a redraw.
    func refresh(item: QuickAccessItem, settings: AppSettings, actions: QuickAccessCardActions) {
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
}
