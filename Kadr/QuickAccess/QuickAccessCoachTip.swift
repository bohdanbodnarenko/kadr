import AppKit
import SwiftUI

/// The one-time popover above the first capture card (docs/03 §2, §8.2).
///
/// A card in the corner of the screen is not self-explanatory. It shows a picture and
/// nothing about it says that hovering reveals what you can do with it, that it can be
/// dragged straight into Slack, or that double-clicking opens the editor — so the commonest
/// outcome for a first capture is that somebody looks at it, cannot tell what it wants, and
/// waits for it to go away. CleanShot solves this with a small popover on the first
/// screenshot, and it is the right solution: taught once, at the only moment the lesson is
/// about something on screen.
///
/// An `NSPopover` rather than a panel of our own, because the arrow, the placement, the
/// material and the dismissal are all things AppKit already does correctly and a hand-built
/// version would get subtly wrong.
@MainActor
final class QuickAccessCoachTip {
    private var popover: NSPopover?
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var isShowing: Bool {
        popover?.isShown ?? false
    }

    /// Shows the tip pointing at a card.
    ///
    /// - Parameters:
    ///   - rect: the card's frame, in `anchor`'s coordinates.
    ///   - anchor: the view that rect belongs to — the overlay's hosting view, which holds
    ///     the whole stack.
    ///   - preferredEdge: which side of the card to sit on. Chosen by the caller from the
    ///     corner the stack is docked in, so the tip never points off the screen.
    func show(relativeTo rect: NSRect, of anchor: NSView, preferredEdge: NSRectEdge) {
        guard popover == nil else { return }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 208)
        // Application-defined, not transient. A transient popover closes when the app stops
        // being active, and this app is *never* active — it is an accessory that shows a
        // card without taking focus, so a transient tip would be dismissed by the same
        // frontmost application it was trying to teach the user about.
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(
            rootView: QuickAccessCoachTipView { [weak self] in self?.dismiss() }
        )
        popover.show(relativeTo: rect, of: anchor, preferredEdge: preferredEdge)
        self.popover = popover
    }

    func dismiss() {
        guard let popover else { return }
        popover.performClose(nil)
        popover.contentViewController = nil
        self.popover = nil
        onDismiss()
    }
}

/// What a card can do, said once.
private struct QuickAccessCoachTipView: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("That is your first capture.")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                tip(
                    symbol: "cursorarrow",
                    title: "Hover it",
                    detail: "The actions appear — copy, save, annotate, pin."
                )
                tip(
                    symbol: "hand.draw",
                    title: "Drag it anywhere",
                    detail: "Straight into Slack, Mail or a folder. The file is made as it lands."
                )
                tip(
                    symbol: "pencil.tip.crop.circle",
                    title: "Double-click to edit",
                    detail: "Arrows, text, blur — or the studio, for a recording."
                )
            }

            Text("It tidies itself away on its own. Swipe it toward the edge to hide it sooner.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Got it", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func tip(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
