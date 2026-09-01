import CoreGraphics
import Foundation
import Testing
@testable import StudioSession

@Suite("Overlay placement")
struct OverlayPlacementTests {
    private let card = CGRect(x: 40, y: 20, width: 400, height: 200)
    private let pill = CGSize(width: 80, height: 24)
    private let margin: CGFloat = 10

    @Test("Bottom centre is the default keystroke slot")
    func defaultsMatchTheOldHardcodedSlots() {
        let bottom = OverlayPlacement.bottom.frame(for: pill, in: card, margin: margin)
        #expect(abs(bottom.midX - card.midX) < 0.001)
        #expect(abs(bottom.maxY - (card.maxY - margin)) < 0.001)

        let top = OverlayPlacement.top.frame(for: pill, in: card, margin: margin)
        #expect(abs(top.midX - card.midX) < 0.001)
        #expect(abs(top.minY - (card.minY + margin)) < 0.001)
    }

    @Test("Each slot sits on its named edge of the card")
    func namedEdges() {
        let leading = OverlayPlacement.topLeading.frame(for: pill, in: card, margin: margin)
        #expect(abs(leading.minX - (card.minX + margin)) < 0.001)
        #expect(abs(leading.minY - (card.minY + margin)) < 0.001)

        let trailing = OverlayPlacement.bottomTrailing.frame(for: pill, in: card, margin: margin)
        #expect(abs(trailing.maxX - (card.maxX - margin)) < 0.001)
        #expect(abs(trailing.maxY - (card.maxY - margin)) < 0.001)
    }

    @Test("A caption wider than the card is clamped onto it")
    func oversizedCaptionStaysOnTheCard() {
        let huge = OverlayPlacement.bottom.frame(
            for: CGSize(width: 2000, height: 80),
            in: card,
            margin: margin
        )
        #expect(huge.minX >= card.minX)
        #expect(huge.maxX <= card.maxX + 0.001)
        #expect(huge.width <= card.width - margin * 2 + 0.001)
    }

    @Test("An old edit without placement fields still opens")
    func placementDefaultsAbsent() throws {
        let edit = try JSONDecoder().decode(StudioEdit.self, from: Data(#"{"version": 1}"#.utf8))
        #expect(edit.keystrokePlacement == .bottom)
        #expect(edit.captionPlacement == .top)
        #expect(edit.soundtrackFileName == nil)
        #expect(edit.keystrokeScale == 1)
        #expect(edit.captionScale == 1)
        #expect(edit.highlightsSpokenWord)
    }
}
