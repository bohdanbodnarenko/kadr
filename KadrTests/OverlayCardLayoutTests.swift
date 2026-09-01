import AppKit
import Foundation
import SettingsKit
import Testing
@testable import Kadr

/// Where the cards sit, and how big the window around one is (docs/03 §2).
///
/// The panel is deliberately larger than the card it shows: a window clips its content, and
/// the card used to fill its panel exactly, so the shadow that lifts it off the desktop was
/// cut off at the edges and a hover that scaled the card pushed the buttons along its edges
/// outside the window and hid them. The margin is where the shadow lives — which means every
/// position here is about the *visible* card rather than the window.
@MainActor
@Suite("Overlay card layout")
struct OverlayCardLayoutTests {
    private func makeHarness() -> TestHarness {
        makeManager(
            saveFolder: temporaryDirectory("save"),
            stagingFolder: temporaryDirectory("stage")
        )
    }

    private var panelSize: CGSize {
        CGSize(width: 224, height: 200)
    }

    private let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    /// The visible card keeps the screen margin it is supposed to, not the margin plus a
    /// shadow's width.
    @Test("The visible card sits at the screen margin, not the panel")
    func visibleCardHonoursTheScreenMargin() {
        let harness = makeHarness()
        harness.settings.overlayCorner = .topRight

        let origin = harness.manager.cardOrigin(index: 0, size: panelSize, area: area, maxVisible: 3)
        let bleed = QuickAccessCardView.shadowMargin
        // The card's own right edge, once the invisible margin is taken off.
        let cardRight = origin.x + panelSize.width - bleed
        #expect(abs(cardRight - (area.maxX - QuickAccessManager.screenMargin)) < 0.001)

        let cardTop = origin.y + panelSize.height - bleed
        #expect(abs(cardTop - (area.maxY - QuickAccessManager.screenMargin)) < 0.001)
    }

    @Test("A leading corner is measured the same way")
    func leadingCornerHonoursTheMargin() {
        let harness = makeHarness()
        harness.settings.overlayCorner = .bottomLeft

        let origin = harness.manager.cardOrigin(index: 0, size: panelSize, area: area, maxVisible: 3)
        let bleed = QuickAccessCardView.shadowMargin
        #expect(abs((origin.x + bleed) - (area.minX + QuickAccessManager.screenMargin)) < 0.001)
        #expect(abs((origin.y + bleed) - (area.minY + QuickAccessManager.screenMargin)) < 0.001)
    }

    /// Cards in a stack are spaced by what the eye sees between them. Spacing off the panel
    /// would add a shadow's width to every gap.
    @Test("Stack spacing is measured between visible cards")
    func stackSpacingIsVisible() {
        let harness = makeHarness()
        harness.settings.overlayCorner = .topRight

        let first = harness.manager.cardOrigin(index: 0, size: panelSize, area: area, maxVisible: 3)
        let second = harness.manager.cardOrigin(index: 1, size: panelSize, area: area, maxVisible: 3)
        let bleed = QuickAccessCardView.shadowMargin
        let visibleHeight = panelSize.height - bleed * 2

        let gap = (first.y) - (second.y + panelSize.height)
        // Two visible edges, `cardSpacing` apart, with the two invisible margins between.
        #expect(
            abs(gap + bleed * 2 - QuickAccessManager.cardSpacing) < 0.001,
            "the gap between cards is not the spacing it is set to"
        )
        #expect(visibleHeight > 0)
    }

    /// The window has to be bigger than the card, or the shadow is clipped again and a
    /// button on the edge is cut in half.
    @Test("The panel is larger than the card by the shadow margin")
    func panelIsLargerThanTheCard() {
        let card: CGFloat = 200
        let panel = QuickAccessCardView.panelWidth(forCardWidth: card)
        #expect(abs(panel - (card + QuickAccessCardView.shadowMargin * 2)) < 0.001)
        #expect(panel > card)
    }
}
