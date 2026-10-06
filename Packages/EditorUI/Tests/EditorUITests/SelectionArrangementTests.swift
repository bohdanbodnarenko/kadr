import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// Align and distribute (docs/18 ED-7).
@Suite("Selection arrangement")
struct SelectionArrangementTests {
    private static let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)
    private static let pair = [
        CGRect(x: 10, y: 20, width: 40, height: 40),
        CGRect(x: 100, y: 200, width: 60, height: 20)
    ]

    @Test("Several items align to the selection's own bounds", arguments: [
        (SelectionArrangement.Alignment.left, [CGSize(width: 0, height: 0), CGSize(width: -90, height: 0)]),
        (.right, [CGSize(width: 110, height: 0), CGSize(width: 0, height: 0)]),
        (.centerX, [CGSize(width: 55, height: 0), CGSize(width: -45, height: 0)]),
        (.top, [CGSize(width: 0, height: 0), CGSize(width: 0, height: -180)]),
        (.bottom, [CGSize(width: 0, height: 160), CGSize(width: 0, height: 0)]),
        (.middle, [CGSize(width: 0, height: 80), CGSize(width: 0, height: -90)])
    ])
    func alignPair(alignment: SelectionArrangement.Alignment, expected: [CGSize]) {
        #expect(SelectionArrangement.align(Self.pair, alignment, canvas: Self.canvas) == expected)
    }

    @Test("A single item aligns to the canvas", arguments: [
        (SelectionArrangement.Alignment.left, CGSize(width: -10, height: 0)),
        (.right, CGSize(width: 750, height: 0)),
        (.middle, CGSize(width: 0, height: 260))
    ])
    func alignSingle(alignment: SelectionArrangement.Alignment, expected: CGSize) {
        let box = CGRect(x: 10, y: 20, width: 40, height: 40)
        #expect(SelectionArrangement.align([box], alignment, canvas: Self.canvas) == [expected])
    }

    @Test("Distribute leaves equal gaps and keeps the ends, in any input order")
    func distributeHorizontally() {
        let boxes = [
            CGRect(x: 200, y: 0, width: 10, height: 10),
            CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: 50, y: 0, width: 30, height: 10)
        ]
        let moves = SelectionArrangement.distribute(boxes, along: .horizontal)
        #expect(moves[0] == .zero)
        #expect(moves[1] == .zero)
        // Span 0…210, items 50 wide in all, so two gaps of 80: the middle starts at 90.
        #expect(moves[2] == CGSize(width: 40, height: 0))
    }

    @Test("Fewer than three items do not distribute")
    func distributeNeedsThree() {
        #expect(SelectionArrangement.distribute(Self.pair, along: .vertical) == [.zero, .zero])
    }

    @MainActor
    @Test("Aligning is one undo step")
    func alignIsOneStep() {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        let first = AnnotationCommand.shape(ShapeSpec(rect: CGRect(x: 10, y: 10, width: 20, height: 20)))
        let second = AnnotationCommand.shape(ShapeSpec(rect: CGRect(x: 300, y: 90, width: 20, height: 20)))
        model.document.add(first)
        model.document.add(second)
        model.document.selection = [first.id, second.id]
        let before = model.document.historyPosition

        model.alignSelection(.top)

        #expect(model.document.historyPosition == before + 1)
        let tops = model.document.commands.map { AnnotationHitTesting.boundingBox(of: $0).minY }
        #expect(Set(tops).count == 1)
    }
}
