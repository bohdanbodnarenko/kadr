import Foundation
import SettingsKit
import SwiftUI

/// Where the stack sits and which way it moves, for a given corner (docs/03 §2).
///
/// Pure functions, separate from the view, because this is the part with a right answer:
/// which end of the column the newest card belongs at, which edge a card slides in from,
/// and how many fit before the rest have to tuck behind. A `View` body is a bad place to
/// keep arithmetic nobody can test.
enum QuickAccessStackLayout {
    /// Cards in the order the column draws them, top to bottom.
    ///
    /// `items` is newest-first, and the newest card always sits nearest the docked corner:
    /// a capture should appear in the same place every time, rather than pushing the last
    /// one aside and landing somewhere new. For a top corner that is the natural order; for
    /// a bottom corner the column has to be reversed, because "first" in a `VStack` means
    /// the top.
    static func ordered<Item>(_ items: [Item], corner: OverlayCorner) -> [Item] {
        corner.isBottom ? items.reversed() : items
    }

    /// The corner of the panel the column is pinned to.
    static func alignment(for corner: OverlayCorner) -> Alignment {
        switch (corner.isBottom, corner.isLeading) {
        case (true, true): .bottomLeading
        case (true, false): .bottomTrailing
        case (false, true): .topLeading
        case (false, false): .topTrailing
        }
    }

    /// The edge a card enters from and leaves towards: the one it is docked against.
    ///
    /// Sliding in from the near side reads as the card arriving from off-screen. Sliding
    /// it in from the far side would send it across the user's work to get here.
    static func slideEdge(for corner: OverlayCorner) -> Edge {
        corner.isLeading ? .leading : .trailing
    }

    /// Which way the stack travels to tuck itself away, in points of `offset(y:)`.
    ///
    /// The peek tab replaces the stack in the same corner, so the stack leaves towards the
    /// nearest horizontal edge and the pill arrives from it.
    static func hideDirection(for corner: OverlayCorner) -> CGFloat {
        corner.isBottom ? 1 : -1
    }

    /// How many whole cards fit in the height available, at least one.
    ///
    /// A stack taller than the screen is worse than a truncated one: the oldest cards run
    /// off the top under the menu bar, and on a short display the newest can end up there
    /// too. The configured maximum is an upper bound, not a promise — this is the other.
    static func capacity(
        height: CGFloat,
        cardHeight: CGFloat,
        spacing: CGFloat,
        margin: CGFloat
    ) -> Int {
        let available = height - margin * 2
        let stride = cardHeight + spacing
        guard available > 0, stride > 0 else { return 1 }
        return max(1, Int((available + spacing) / stride))
    }

    /// Whether a card should show the newest-capture dot (CleanShot §6.3).
    ///
    /// Only when more than one card is visible — a lone card does not need a label for
    /// being the newest.
    static func showsNewestIndicator(for itemID: UUID, in items: [QuickAccessItem]) -> Bool {
        items.count > 1 && items.first?.id == itemID
    }

    /// Whether the trash control should appear (CleanShot §6.2).
    ///
    /// Auto-saved captures are already on disk, so hiding the card is not enough — the user
    /// needs a one-click way to throw the file away.
    static func showsTrashButton(for item: QuickAccessItem) -> Bool {
        !item.isStaged
    }
}
