import CoreGraphics
import Testing
@testable import AnnotationModel

/// Edge and centre snapping (docs/18 ED-7).
@Suite("Snap guides")
struct SnapGuidesTests {
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test("Edges and centres snap within the threshold", arguments: [
        // Left edge 3 pt from the canvas edge.
        (CGRect(x: 3, y: 300, width: 100, height: 50), CGSize(width: -3, height: 0)),
        // Centre 2 pt right of the canvas centre (500), middle 1 pt above (400).
        (CGRect(x: 452, y: 374, width: 100, height: 50), CGSize(width: -2, height: 1)),
        // Right edge 4 pt short of the canvas's right edge.
        (CGRect(x: 896, y: 300, width: 100, height: 50), CGSize(width: 4, height: 0)),
        // Nothing near anything.
        (CGRect(x: 200, y: 200, width: 100, height: 50), CGSize.zero)
    ])
    func snapsToCanvas(moving: CGRect, expected: CGSize) {
        let result = SnapGuides.snap(moving, to: [canvas], threshold: 5)
        #expect(result.adjustment == expected)
        #expect(result.guides.count == [expected.width, expected.height].filter { $0 != 0 }.count)
    }

    @Test("Another annotation's edge is a target, and the closest line wins")
    func snapsToNeighbour() {
        let neighbour = CGRect(x: 300, y: 100, width: 80, height: 80)
        let moving = CGRect(x: 302, y: 600, width: 50, height: 50)
        let result = SnapGuides.snap(moving, to: [canvas, neighbour], threshold: 5)
        #expect(result.adjustment.width == -2)
        #expect(result.guides.first == SnapGuides.Guide(axis: .vertical, position: 300))
    }

    @Test("A zero threshold never moves anything")
    func zeroThreshold() {
        let result = SnapGuides.snap(CGRect(x: 1, y: 1, width: 10, height: 10), to: [canvas], threshold: 0)
        #expect(result.adjustment == .zero)
    }
}
