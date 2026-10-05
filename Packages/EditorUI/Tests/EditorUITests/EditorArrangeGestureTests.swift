import AnnotationModel
import CoreGraphics
import Testing
@testable import EditorUI

/// Snapping, ⌥-drag duplicate, ⇧-click and paste cascade (docs/18 ED-7).
@MainActor
@Suite("Arranging on the canvas")
struct EditorArrangeGestureTests {
    private func makeModel(_ commands: [AnnotationCommand]) -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2),
            commands: commands
        ))
    }

    private func shape(_ rect: CGRect) -> AnnotationCommand {
        .shape(ShapeSpec(rect: rect, fill: FillStyle(color: .white)))
    }

    private func rect(of command: AnnotationCommand?) -> CGRect? {
        guard case let .shape(spec)? = command else { return nil }
        return spec.rect
    }

    @Test("A move near the canvas edge lands on it, and ⌘ suspends the pull")
    func snapsToCanvasEdge() {
        let model = makeModel([shape(CGRect(x: 100, y: 100, width: 50, height: 50))])
        model.tool = .select
        model.pointerDown(at: CGPoint(x: 120, y: 120))
        model.pointerDragged(to: CGPoint(x: 23, y: 120))
        // The visible edge, stroke included, is what lands on the canvas edge.
        let moved = model.document.commands.first.map(AnnotationHitTesting.boundingBox)
        #expect(abs((moved?.minX ?? 99) - 0) < 0.001)
        #expect(!model.snapGuides.isEmpty)
        model.pointerDragged(to: CGPoint(x: 23, y: 120), modifiers: .extendSelection)
        #expect(rect(of: model.document.commands.first)?.minX == 3)
        model.pointerUp(at: CGPoint(x: 23, y: 120))
        #expect(model.snapGuides.isEmpty)
    }

    @Test("⌥-drag leaves the original and moves a copy, in one undo step")
    func optionDragDuplicates() {
        let original = shape(CGRect(x: 300, y: 300, width: 40, height: 40))
        let model = makeModel([original])
        model.tool = .select
        model.pointerDown(at: CGPoint(x: 310, y: 310), modifiers: .fromCenter)
        model.pointerDragged(to: CGPoint(x: 410, y: 330), modifiers: .fromCenter)
        model.pointerUp(at: CGPoint(x: 410, y: 330), modifiers: .fromCenter)

        #expect(model.document.commands.count == 2)
        #expect(rect(of: model.document.commands.first) == CGRect(x: 300, y: 300, width: 40, height: 40))
        #expect(!model.selection.contains(original.id))
        model.undo()
        #expect(model.document.commands == [original])
    }

    @Test("An ⌥-click without movement copies nothing")
    func optionClickDoesNotDuplicate() {
        let model = makeModel([shape(CGRect(x: 300, y: 300, width: 40, height: 40))])
        model.tool = .select
        model.pointerDown(at: CGPoint(x: 310, y: 310), modifiers: .fromCenter)
        model.pointerUp(at: CGPoint(x: 310, y: 310), modifiers: .fromCenter)
        #expect(model.document.commands.count == 1)
    }

    @Test("⇧-click adds to the selection and never removes")
    func shiftClickExtends() {
        let first = shape(CGRect(x: 10, y: 10, width: 40, height: 40))
        let second = shape(CGRect(x: 200, y: 200, width: 40, height: 40))
        let model = makeModel([first, second])
        model.tool = .select
        model.pointerDown(at: CGPoint(x: 20, y: 20))
        model.pointerUp(at: CGPoint(x: 20, y: 20))
        model.pointerDown(at: CGPoint(x: 210, y: 210), modifiers: .constrain)
        model.pointerUp(at: CGPoint(x: 210, y: 210), modifiers: .constrain)
        #expect(model.selection == [first.id, second.id])
        model.pointerDown(at: CGPoint(x: 210, y: 210), modifiers: .constrain)
        model.pointerUp(at: CGPoint(x: 210, y: 210), modifiers: .constrain)
        #expect(model.selection == [first.id, second.id])
    }

    @Test("A run of nudges is one undo step; a different selection starts a new one")
    func nudgesCoalesce() {
        let first = shape(CGRect(x: 100, y: 100, width: 40, height: 40))
        let second = shape(CGRect(x: 300, y: 300, width: 40, height: 40))
        let model = makeModel([first, second])
        model.selection = [first.id]
        for _ in 0 ..< 5 {
            model.nudgeSelection(dx: 1, dy: 0)
        }
        #expect(rect(of: model.document.commands.first)?.minX == 105)
        model.selection = [second.id]
        model.nudgeSelection(dx: 0, dy: 1)

        model.undo()
        #expect(rect(of: model.document.commands.last)?.minY == 300)
        #expect(rect(of: model.document.commands.first)?.minX == 105)
        model.undo()
        #expect(rect(of: model.document.commands.first)?.minX == 100)
        #expect(!model.canUndo)
    }

    @Test("Repeated pastes step away from the center")
    func pasteCascade() {
        let model = makeModel([])
        let first = model.nextPastePoint()
        let second = model.nextPastePoint()
        #expect(first == CGPoint(x: model.document.contentRect.midX, y: model.document.contentRect.midY))
        #expect(second.x == first.x + 16 && second.y == first.y + 16)
    }
}
