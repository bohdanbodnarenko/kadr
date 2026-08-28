import CoreGraphics
import Foundation
import Shared
import Testing
@testable import SelectionUI

/// Snapping the selection to the edges in the frozen screen (docs/03 §8.3, docs/06 M21).
@Suite("Selection snapping")
struct SelectionSnappingTests {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// A 2× display, with lines at 100 and 600 px across and 80 and 400 px down —
    /// 50/300 pt and 40/200 pt in the space the selection lives in.
    private var snapping: SelectionSnapping {
        SelectionSnapping(
            candidates: EdgeCandidates(
                verticalEdges: [100, 600],
                horizontalEdges: [80, 400],
                pixelSize: PixelSize(width: 1600, height: 1200)
            ),
            scale: 2,
            tolerance: 6
        )
    }

    private func interaction() -> SelectionInteraction {
        var interaction = SelectionInteraction(bounds: bounds)
        interaction.snapping = snapping
        return interaction
    }

    @Test("A drag that ends near a border lands on it")
    func dragSnaps() throws {
        var interaction = interaction()
        interaction.begin(at: CGPoint(x: 52, y: 42))
        interaction.drag(to: CGPoint(x: 298, y: 198))
        let rect = try #require(interaction.rect)

        #expect(rect.minX == 50)
        #expect(rect.minY == 40)
        #expect(rect.maxX == 300)
        #expect(rect.maxY == 200)
    }

    @Test("⌘ during the drag turns snapping off")
    func commandDisablesSnapping() throws {
        var interaction = interaction()
        interaction.begin(at: CGPoint(x: 52, y: 42))
        interaction.drag(to: CGPoint(x: 298, y: 198), modifiers: .freeform)
        let rect = try #require(interaction.rect)

        #expect(rect.minX == 52)
        #expect(rect.maxX == 298)
    }

    /// A square that snaps is not a square any more, and ⇧ is a promise about the shape.
    @Test("⇧ wins over snapping, because a locked aspect is a stronger promise")
    func lockedAspectWinsOverSnapping() throws {
        var interaction = interaction()
        interaction.begin(at: CGPoint(x: 52, y: 42))
        interaction.drag(to: CGPoint(x: 298, y: 100), modifiers: .lockAspect)
        let rect = try #require(interaction.rect)

        #expect(rect.width == rect.height)
    }

    @Test("A drag nowhere near a line is left exactly where it was put")
    func farDragDoesNotSnap() throws {
        var interaction = interaction()
        interaction.begin(at: CGPoint(x: 200, y: 250))
        interaction.drag(to: CGPoint(x: 260, y: 290))
        let rect = try #require(interaction.rect)

        #expect(rect.minX == 200)
        #expect(rect.minY == 250)
        #expect(rect.maxX == 260)
        #expect(rect.maxY == 290)
    }

    @Test("Without detected edges, nothing changes")
    func noCandidatesNoSnapping() throws {
        var interaction = SelectionInteraction(bounds: bounds)
        interaction.snapping = SelectionSnapping(candidates: .none, scale: 2)
        interaction.begin(at: CGPoint(x: 52, y: 42))
        interaction.drag(to: CGPoint(x: 298, y: 198))
        let rect = try #require(interaction.rect)

        #expect(rect.minX == 52)
    }

    @Test("Snapping never pushes the selection off the display")
    func staysInsideBounds() throws {
        var interaction = SelectionInteraction(bounds: bounds)
        interaction.snapping = SelectionSnapping(
            candidates: EdgeCandidates(
                verticalEdges: [0, 1600],
                horizontalEdges: [0, 1200],
                pixelSize: PixelSize(width: 1600, height: 1200)
            ),
            scale: 2,
            tolerance: 6
        )
        interaction.begin(at: CGPoint(x: 2, y: 2))
        interaction.drag(to: CGPoint(x: 798, y: 598))
        let rect = try #require(interaction.rect)

        #expect(bounds.contains(rect))
    }

    @Test("An empty rect is returned untouched rather than snapped to nothing")
    func emptyRectIsUntouched() {
        let rect = CGRect(x: 10, y: 10, width: 0, height: 0)
        #expect(snapping.snapped(rect) == rect)
    }

    @Test("A zero tolerance is the same as no snapping")
    func zeroToleranceIsOff() {
        var value = snapping
        value.tolerance = 0
        #expect(value.isEmpty)
        let rect = CGRect(x: 52, y: 42, width: 100, height: 100)
        #expect(value.snapped(rect) == rect)
    }
}
