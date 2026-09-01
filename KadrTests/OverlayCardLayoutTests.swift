import AppKit
import Foundation
import SettingsKit
import SwiftUI
import Testing
@testable import Kadr

/// Where the stack sits and which way it moves (docs/03 §2).
///
/// This arithmetic used to live in the manager, positioning one window per card. It moved
/// into `QuickAccessStackLayout` when the cards moved into a single panel, and the reason
/// it is a set of pure functions is this file: "which end of the column does the newest
/// card go" has a right answer for each of four corners, and a `View` body is a bad place
/// to keep an answer nobody can check.
@MainActor
@Suite("Overlay stack layout")
struct OverlayCardLayoutTests {
    private let corners: [OverlayCorner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    /// The newest capture appears in the same place every time.
    ///
    /// A `VStack` draws its first element at the top, so a column docked to a bottom corner
    /// has to be reversed to put the newest card nearest that corner. Get this wrong and
    /// each capture pushes the last one aside and lands somewhere new, which is the one
    /// thing a card in a fixed corner must not do.
    @Test("The newest card is nearest the docked corner")
    func newestCardIsNearestTheCorner() {
        let items = [1, 2, 3]

        for corner in corners where !corner.isBottom {
            let ordered = QuickAccessStackLayout.ordered(items, corner: corner)
            #expect(ordered.first == 1, "a top corner draws the newest card first")
        }

        for corner in corners where corner.isBottom {
            let ordered = QuickAccessStackLayout.ordered(items, corner: corner)
            #expect(ordered.last == 1, "a bottom corner draws the newest card last, nearest the edge")
        }
    }

    @Test("Ordering keeps every card")
    func orderingIsAPermutation() {
        for corner in corners {
            let ordered = QuickAccessStackLayout.ordered([1, 2, 3], corner: corner)
            #expect(ordered.sorted() == [1, 2, 3])
        }
    }

    /// Cards arrive from the edge they are docked against, so one never crosses the
    /// user's work to get to its corner.
    @Test("Cards slide in from the side they are docked on")
    func cardsSlideInFromTheDockedEdge() {
        #expect(QuickAccessStackLayout.slideEdge(for: .topLeft) == .leading)
        #expect(QuickAccessStackLayout.slideEdge(for: .bottomLeft) == .leading)
        #expect(QuickAccessStackLayout.slideEdge(for: .topRight) == .trailing)
        #expect(QuickAccessStackLayout.slideEdge(for: .bottomRight) == .trailing)
    }

    @Test("Each corner pins the column to itself")
    func alignmentMatchesTheCorner() {
        #expect(QuickAccessStackLayout.alignment(for: .topLeft) == .topLeading)
        #expect(QuickAccessStackLayout.alignment(for: .topRight) == .topTrailing)
        #expect(QuickAccessStackLayout.alignment(for: .bottomLeft) == .bottomLeading)
        #expect(QuickAccessStackLayout.alignment(for: .bottomRight) == .bottomTrailing)
    }

    /// A stack tucks itself away past the edge it is docked against, not across the screen.
    @Test("The stack hides towards its own edge")
    func hideDirectionFollowsTheCorner() {
        #expect(QuickAccessStackLayout.hideDirection(for: .bottomLeft) > 0)
        #expect(QuickAccessStackLayout.hideDirection(for: .bottomRight) > 0)
        #expect(QuickAccessStackLayout.hideDirection(for: .topLeft) < 0)
        #expect(QuickAccessStackLayout.hideDirection(for: .topRight) < 0)
    }

    /// Capacity counts whole cards, gaps included, inside the margins.
    @Test(
        "Capacity is how many cards actually fit",
        arguments: [
            // height, cardHeight, expected
            (CGFloat(1000), CGFloat(148), 6),
            (CGFloat(400), CGFloat(148), 2),
            (CGFloat(220), CGFloat(148), 1)
        ]
    )
    func capacityCountsWholeCards(height: CGFloat, cardHeight: CGFloat, expected: Int) {
        let capacity = QuickAccessStackLayout.capacity(
            height: height,
            cardHeight: cardHeight,
            spacing: QuickAccessManager.cardSpacing,
            margin: QuickAccessManager.screenMargin
        )
        #expect(capacity == expected)

        // Whatever it returns has to actually fit, or the oldest cards run off the screen.
        let used = CGFloat(capacity) * cardHeight + CGFloat(capacity - 1) * QuickAccessManager.cardSpacing
        #expect(
            capacity == 1 || used <= height - QuickAccessManager.screenMargin * 2,
            "a capacity of \(capacity) does not fit in \(height)"
        )
    }

    /// A display too short for even one card still gets one — a card half off the screen
    /// beats a capture the user is never told about.
    @Test("Capacity never reaches zero")
    func capacityIsAtLeastOne() {
        for height in [CGFloat(0), 10, 40, -100] {
            let capacity = QuickAccessStackLayout.capacity(
                height: height,
                cardHeight: 148,
                spacing: QuickAccessManager.cardSpacing,
                margin: QuickAccessManager.screenMargin
            )
            #expect(capacity == 1)
        }
    }

    /// The card's height follows its width setting.
    ///
    /// It used to be a fixed 104 points at every width. The width setting runs from 140 to
    /// 420, so at the wide end the card was a letterbox showing a strip cropped out of the
    /// middle of the capture — wider, but not showing any more of it.
    @Test("A wider card is a taller card")
    func cardHeightFollowsWidth() {
        let narrow = QuickAccessCardView.height(forWidth: 140)
        let wide = QuickAccessCardView.height(forWidth: 420)
        #expect(wide > narrow)
        #expect(narrow > 0)
        // Landscape at both ends, because captures are.
        #expect(narrow < 140)
        #expect(wide < 420)
    }
}

/// Click, double-click and drag all come from one view, so something has to tell them apart
/// (docs/03 §2).
@MainActor
@Suite("Card gestures")
struct CardGestureTests {
    /// The bug this exists for: the threshold was 3 points, which is less than the wobble in
    /// an ordinary double-click. The first click started a drag, the card snapped back, and
    /// the double-click was swallowed — so double-clicking a card never opened the editor.
    @Test("A double-click's wobble is not a drag")
    func doubleClickWobbleIsNotADrag() {
        for travelled in [CGFloat(0), 1, 3, 5, 8, 9.9] {
            #expect(
                !CardDragGesture.shouldBeginDrag(travelled: travelled, clickCount: 1),
                "\(travelled) points of wobble started a drag"
            )
        }
    }

    @Test("A deliberate pull is a drag")
    func deliberatePullIsADrag() {
        #expect(CardDragGesture.shouldBeginDrag(travelled: 10, clickCount: 1))
        #expect(CardDragGesture.shouldBeginDrag(travelled: 40, clickCount: 1))
    }

    /// Whatever the pointer does afterwards, the second click of a double-click is not the
    /// start of a drag.
    @Test("The second click of a double-click never drags")
    func secondClickNeverDrags() {
        for travelled in [CGFloat(0), 10, 100] {
            #expect(!CardDragGesture.shouldBeginDrag(travelled: travelled, clickCount: 2))
            #expect(!CardDragGesture.shouldBeginDrag(travelled: travelled, clickCount: 3))
        }
    }
}

/// The hover chrome has to fit inside the card it is drawn over (docs/03 §2).
@MainActor
@Suite("Card action layout")
struct CardActionLayoutTests {
    /// The bug: the default layout puts nine actions in the column slot, drawn as one
    /// `HStack`. That is 302 points of buttons inside a 200-point card, clipped at both ends
    /// by the card's own rounded shape — the outer two sliced in half, the rest invisible.
    @Test("Every action fits inside the card at any width it can be set to")
    func actionsFitTheCard() {
        let actions = CardLayout.standard.actions(in: .column, for: .screenshot)
        #expect(actions.count > 1, "this only proves something if the default row is crowded")

        for width in [CGFloat(140), 160, 200, 280, 420] {
            let rows = QuickAccessCardView.actionRows(actions, width: width)
            let widest = rows.map(\.count).max() ?? 0
            let used = CGFloat(widest) * QuickAccessCardView.actionButtonSize
                + CGFloat(max(0, widest - 1)) * QuickAccessCardView.actionSpacing
            let available = width - QuickAccessCardView.chromeInset * 2
            #expect(used <= available, "a row of \(widest) needs \(used) in \(available) at width \(width)")
            #expect(rows.flatMap(\.self) == actions, "wrapping must not drop or reorder an action")
        }
    }

    /// A wider card puts more on a row, which is the only reason to wrap by width at all.
    @Test("A wider card fits more buttons per row")
    func widerCardsFitMore() {
        #expect(QuickAccessCardView.actionsPerRow(width: 420) > QuickAccessCardView.actionsPerRow(width: 140))
        #expect(QuickAccessCardView.actionsPerRow(width: 140) >= 1)
    }
}
