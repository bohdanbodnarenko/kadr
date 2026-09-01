import AppKit
import SettingsKit
import SwiftUI

/// Collects the frames of the overlay's interactive parts, in hosting-view coordinates.
///
/// The panel covers the whole screen, so it has to be told which bits of itself are real;
/// only the layout knows, and only after it has run.
struct QuickAccessInteractiveRectsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

extension View {
    /// Publishes this view's frame as somewhere clicks should land.
    ///
    /// `active: false` stops reporting, which matters for the half of the overlay that is
    /// currently slid off-screen — otherwise it would go on taking clicks at the place it
    /// would have been.
    func reportsInteractiveRect(active: Bool = true) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: QuickAccessInteractiveRectsKey.self,
                    value: active ? [proxy.frame(in: .global)] : []
                )
            }
        )
    }
}

/// The card stack and its peek tab, in one panel (docs/03 §2).
///
/// Both are mounted the whole time and collapsing slides one out as the other slides in,
/// rather than ordering windows in and out. Two reasons. The obvious one is that it looks
/// like something rather than happening between frames. The other is that show-and-hide of
/// the *items* is a race — there is always a moment where a capture arriving and a stack
/// collapsing disagree about what should be on screen — and a stack that is always present
/// has no such moment to get wrong.
struct QuickAccessStackView: View {
    let manager: QuickAccessManager
    /// Called with the frames that should take clicks; everything else passes through.
    let onInteractiveRects: ([CGRect]) -> Void

    /// Slow enough to read, quick enough not to be in the way. No bounce: cards carry a
    /// picture of the user's work, and overshoot on a thumbnail reads as a wobble.
    static let animation = Animation.smooth(duration: 0.3, extraBounce: 0)

    @State private var isReflowing = false
    @State private var reflowReset: Task<Void, Never>?
    @State private var stackHeight: CGFloat = 400
    @State private var peekHeight: CGFloat = 48
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var corner: OverlayCorner {
        manager.settings.overlayCorner
    }

    private var stackIsHidden: Bool {
        manager.isPeeking
    }

    private var motion: Animation? {
        reduceMotion ? nil : Self.animation
    }

    var body: some View {
        GeometryReader { proxy in
            let alignment = QuickAccessStackLayout.alignment(for: corner)
            let direction = QuickAccessStackLayout.hideDirection(for: corner)

            ZStack {
                column(availableHeight: proxy.size.height)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stackHeight = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .padding(QuickAccessManager.screenMargin)
                    .offset(y: stackIsHidden ? stackHiddenOffset * direction : 0)

                peekTab
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { peekHeight = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .padding(QuickAccessManager.screenMargin)
                    .offset(y: stackIsHidden ? 0 : peekHiddenOffset * direction)
            }
            // Card arrivals and departures animate only while the stack is out. Collapsed,
            // it is parked off-screen at an offset derived from its own measured height, so
            // animating an item change there would animate the offset against a stale
            // height for a frame — the stack briefly peeking back past the edge it just
            // left. Removing a card behind the peek tab should be invisible.
            .animation(manager.isPeeking ? nil : motion, value: manager.itemIDs)
            .animation(motion, value: manager.isPeeking)
            .onChange(of: manager.itemIDs) { _, _ in
                guard !manager.isPeeking else { return }
                suppressHoverThroughReflow()
            }
            .onChange(of: manager.isPeeking) { _, _ in
                suppressHoverThroughReflow()
            }
            .onPreferenceChange(QuickAccessInteractiveRectsKey.self) { rects in
                Task { @MainActor in onInteractiveRects(rects) }
            }
        }
    }

    // MARK: - The column

    private func column(availableHeight: CGFloat) -> some View {
        let capacity = QuickAccessStackLayout.capacity(
            height: availableHeight,
            cardHeight: QuickAccessCardView.height(forWidth: CGFloat(manager.settings.overlayCardWidth)),
            spacing: QuickAccessManager.cardSpacing,
            margin: QuickAccessManager.screenMargin
        )
        let visibleCount = min(capacity, manager.settings.overlayMaxVisibleCards)
        let items = manager.items
        let visible = QuickAccessStackLayout.ordered(Array(items.prefix(visibleCount)), corner: corner)
        let overflow = QuickAccessStackLayout.ordered(Array(items.dropFirst(visibleCount)), corner: corner)

        return VStack(spacing: QuickAccessManager.cardSpacing) {
            if corner.isBottom {
                slivers(overflow)
                cards(visible)
            } else {
                cards(visible)
                slivers(overflow)
            }
        }
        .frame(width: CGFloat(manager.settings.overlayCardWidth))
        // The whole column, not each card.
        //
        // Reporting cards individually leaves the gaps between them passing clicks through,
        // so the pointer drops out of the hit area every time it crosses one and hover
        // flickers on and off as the user moves down the stack.
        .reportsInteractiveRect(active: !manager.isPeeking && !manager.items.isEmpty)
    }

    private func cards(_ items: [QuickAccessItem]) -> some View {
        ForEach(items) { item in
            QuickAccessCardView(
                item: item,
                actions: manager.actions(for: item),
                width: CGFloat(manager.settings.overlayCardWidth),
                layout: manager.settings.cardLayout,
                suppressHoverChrome: isReflowing
            )
            .transition(
                .move(edge: QuickAccessStackLayout.slideEdge(for: corner))
                    .combined(with: .opacity)
            )
        }
    }

    /// The cards past the visible count, as the edges of a stack (docs/03 §2: "older
    /// collapse behind").
    ///
    /// Not hidden, because the count is the point — the user should be able to see that
    /// there is more here than the screen is showing.
    @ViewBuilder
    private func slivers(_ items: [QuickAccessItem]) -> some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.regularMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.primary.opacity(0.12))
                        )
                        .frame(height: QuickAccessCardView.sliverHeight)
                        .opacity(0.55)
                        .accessibilityLabel("Older capture \(item.filename)")
                }
            }
        }
    }

    // MARK: - The peek tab

    private var peekTab: some View {
        QuickAccessPeekTabView(
            title: OverlayPeekCopy.title(
                count: manager.items.count,
                hasVideo: manager.items.contains(where: \.isVideo)
            ),
            corner: corner,
            onExpand: { manager.setPeeking(false) },
            onDismissAll: { manager.dismissAll() }
        )
        .frame(width: CGFloat(manager.settings.overlayCardWidth))
        .reportsInteractiveRect(active: manager.isPeeking && !manager.items.isEmpty)
    }

    // MARK: - Geometry

    /// Far enough to clear the edge it is docked against, plus the margin it was inset by.
    private var stackHiddenOffset: CGFloat {
        stackHeight + QuickAccessManager.screenMargin + 24
    }

    private var peekHiddenOffset: CGFloat {
        peekHeight + QuickAccessManager.screenMargin + 24
    }

    /// Holds the hover chrome back until the cards have stopped moving.
    ///
    /// A card sliding out from under a stationary pointer fires hover on whichever card
    /// lands there next, so without this a dismissal makes the actions flash across every
    /// card the gap travels past. The delay covers the reflow; the fade back in is so a
    /// card that genuinely settled under the pointer eases into its hovered state rather
    /// than snapping to it.
    private func suppressHoverThroughReflow() {
        guard !reduceMotion else { return }
        isReflowing = true
        reflowReset?.cancel()
        reflowReset = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(340))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                isReflowing = false
            }
        }
    }
}
