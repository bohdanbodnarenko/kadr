import AppKit
import OverlayKit
import Shared
import SwiftUI

/// The overlay's hosting view: first click counts, and clicks land only on the cards.
///
/// Not generic: a `NSHostingView<Content>` subclass crashes Swift 6.3's Release inliner
/// in the synthesized `deinit` (`EarlyPerfInliner` / `OverlayHostingViewCfD`). Erasing to
/// `AnyView` keeps the overrides without that specialization.
final class OverlayHostingView: NSHostingView<AnyView> {
    /// The parts of this view that take clicks, in the view's own coordinates.
    ///
    /// `nil` means the whole view is interactive, which is what a panel sized to its own
    /// content wants. The Quick Access overlay sets it, because that panel covers the
    /// entire screen and almost all of it is empty: without this it would swallow every
    /// click anywhere on the display, which is the single most irritating thing an overlay
    /// can do.
    var interactiveRects: [CGRect]?

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let interactiveRects else { return super.hitTest(point) }

        // Nothing interactive reported yet: fail towards passing the click through, so a
        // frame where the layout has not settled cannot eat somebody's click.
        guard !interactiveRects.isEmpty else { return nil }

        // `point` is in the superview's space. Converting into this view's — flipped,
        // top-left origin, like SwiftUI's `.global` — is what makes it comparable to the
        // frames the stack publishes, with no manual y-flip.
        let local = convert(point, from: superview)
        let slop = InteractiveRegionTracker.hitSlop
        let hit = interactiveRects.contains { $0.insetBy(dx: -slop, dy: -slop).contains(local) }
        return hit ? super.hitTest(point) : nil
    }
}

/// One panel for the whole card stack (docs/03 §2).
///
/// It used to be one panel per card, which is the reason the overlay never felt right. A
/// card's position was its window's position, so restacking meant `setFrameOrigin` on each
/// one — cards teleported to their new places instead of sliding, and docs/03 §2 asks for
/// cards that "slide in". Collapsing to the peek tab was `orderOut`, so it popped. And a
/// card could not draw anything outside its own frame, because a window clips its content:
/// no shadow, no growing under the pointer, nothing.
///
/// With one panel covering the screen, all of that is ordinary SwiftUI. The stack is a
/// `VStack` whose contents animate, cards slide in and out along the docked edge, and the
/// shadow is just a shadow. What the split buys instead is hit-testing: the panel is mostly
/// empty, so `OverlayHostingView.interactiveRects` is what keeps it from swallowing clicks
/// meant for the app underneath.
///
/// Focus is the other delicate part. The panel must never take key status just by appearing
/// — the frontmost app keeps its cursor and its focus ring — but ⌫ has to reach a card once
/// the user is interacting with it. `becomesKeyOnlyIfNeeded` gives exactly that: showing the
/// panel steals nothing, clicking a card hands it the keyboard.
@MainActor
final class QuickAccessOverlayPanel: NonActivatingPanel {
    private let hostingView: OverlayHostingView
    /// Trackpad flicks over a card (docs/03 §2). Set by the manager, which knows which card
    /// the pointer is on.
    var onScroll: ((CGFloat, CGFloat) -> Void)?

    init(content: some View) {
        hostingView = OverlayHostingView(rootView: content)
        hostingView.interactiveRects = []

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Floating, not screen-saver level: cards sit above ordinary windows but below the
        // selection overlay, which must cover everything.
        configureAsOverlay(level: .floating)
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        contentView = hostingView
    }

    /// Covers the screen's visible frame, so the stack can be laid out against any corner
    /// and still clear the Dock and the menu bar (docs/03 §2 accept list).
    func cover(_ screen: NSScreen) {
        let area = screen.visibleFrame
        guard frame != area else { return }
        setFrame(area, display: true)
    }

    func present(on screen: NSScreen) {
        cover(screen)
        orderFrontRegardless()
        // Kept out of Kadr's own captures (docs/09 U2.1).
        CaptureExclusionRegistry.shared.register(self)
    }

    func setContent(_ content: some View) {
        hostingView.setRootView(content)
    }

    /// The frames that take clicks, in the hosting view's coordinates.
    ///
    /// Published by the stack itself through a SwiftUI preference, because only the layout
    /// knows where the cards ended up once an animation has moved them.
    func setInteractiveRects(_ rects: [CGRect]) {
        hostingView.interactiveRects = rects
    }

    /// The view a popover can point at, and the space its frames are in.
    var anchorView: NSView {
        hostingView
    }

    /// The newest card's frame, for anything that needs to point at it.
    ///
    /// The stack reports its column rather than each card, so this is the top or the bottom
    /// of that column depending on which corner it is docked in — whichever end the newest
    /// card is at.
    var newestCardRect: NSRect? {
        hostingView.interactiveRects?.first
    }

    /// A click on a card hands it the keyboard (docs/17 T-OUT-1).
    ///
    /// Card keys act only while this panel is key, so the panel has to become key on the
    /// click itself — SwiftUI's hit views do not ask for it, and `becomesKeyOnlyIfNeeded`
    /// would otherwise leave the keys with the app underneath. Only clicks that land on a
    /// card get here: `hitTest` passes every other click through.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    /// A flick over a card dismisses it or tucks the stack away (docs/03 §2).
    ///
    /// On the panel rather than in SwiftUI: this has to reach the card under the pointer,
    /// and the panel is already the thing that only receives the event when the pointer is
    /// over a card — `hitTest` saw to that.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        guard let onScroll else {
            super.scrollWheel(with: event)
            return
        }
        onScroll(event.scrollingDeltaX, event.scrollingDeltaY)
    }

    func dismiss() {
        CaptureExclusionRegistry.shared.unregister(self)
        contentView = nil
        orderOut(nil)
        close()
    }
}
