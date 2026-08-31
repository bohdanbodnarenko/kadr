import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// Grabbing a selection handle and dragging it (docs/03 §3).
///
/// Handles used to be drawn and then ignored: pointer-down in select mode always started
/// a move. These tests pin that a corner grab resizes, that the opposite corner stays put,
/// and that the whole drag is one undo step — the same history contract as a move.
@MainActor
@Suite("Select-mode resize")
struct EditorResizeTests {
    private func makeModel() -> EditorDocumentModel {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        model.tool = .select
        return model
    }

    @discardableResult
    private func addShape(
        _ model: EditorDocumentModel,
        at origin: CGPoint = CGPoint(x: 100, y: 100),
        size: CGSize = CGSize(width: 60, height: 40)
    ) -> AnnotationID {
        let command = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(origin: origin, size: size),
            stroke: StrokeStyle(width: 0),
            fill: FillStyle(color: .white)
        ))
        model.document.add(command)
        model.document.selection = [command.id]
        return command.id
    }

    private func rect(_ model: EditorDocumentModel, _ id: AnnotationID) -> CGRect? {
        guard case let .shape(spec) = model.document.command(id) else { return nil }
        return spec.rect
    }

    private func handlePoint(_ model: EditorDocumentModel, _ handle: SelectionHandle) -> CGPoint {
        let match = SelectionResizer.anchors(for: model.selectedCommands).first { $0.0 == handle }
        return match?.1 ?? .zero
    }

    private func dragHandle(
        _ model: EditorDocumentModel,
        _ handle: SelectionHandle,
        by delta: CGSize,
        steps: Int = 8,
        modifiers: EditorModifiers = []
    ) {
        let start = handlePoint(model, handle)
        let end = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        model.pointerDown(at: start, modifiers: modifiers)
        for step in 1 ... steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            model.pointerDragged(
                to: CGPoint(
                    x: start.x + delta.width * fraction,
                    y: start.y + delta.height * fraction
                ),
                modifiers: modifiers
            )
        }
        model.pointerUp(at: end, modifiers: modifiers)
    }

    @Test("Dragging the far corner grows the shape; the origin stays put")
    func oppositeCornerStaysPut() throws {
        let model = makeModel()
        let id = addShape(model)

        dragHandle(model, .box(.bottomTrailing), by: CGSize(width: 40, height: 20))

        let grown = try #require(rect(model, id))
        #expect(grown.origin == CGPoint(x: 100, y: 100))
        #expect(grown.size == CGSize(width: 100, height: 60))
    }

    @Test("Grabbing a handle resizes rather than moving the annotation")
    func handleGrabDoesNotMove() throws {
        let model = makeModel()
        let id = addShape(model)

        dragHandle(model, .box(.bottomTrailing), by: CGSize(width: 30, height: 10), steps: 12)

        let grown = try #require(rect(model, id))
        #expect(grown.origin == CGPoint(x: 100, y: 100), "a corner drag must not slide the shape")
        #expect(grown.width > 60)
        #expect(grown.height > 40)
    }

    @Test("A whole resize is a single undo step, however many events it took", arguments: [2, 30])
    func oneResizeIsOneUndoStep(steps: Int) throws {
        let model = makeModel()
        let id = addShape(model)
        let before = try #require(rect(model, id))

        dragHandle(model, .box(.bottomTrailing), by: CGSize(width: 40, height: 20), steps: steps)
        #expect(rect(model, id)?.size == CGSize(width: 100, height: 60))

        model.undo()
        #expect(rect(model, id) == before, "one undo must put the resize back")

        model.undo()
        #expect(model.document.commands.isEmpty)
    }

    @Test("A click on a handle that does not move costs no undo step")
    func clickWithoutMovingIsNotAnEdit() {
        let model = makeModel()
        let id = addShape(model)
        let start = handlePoint(model, .box(.bottomTrailing))

        model.pointerDown(at: start)
        model.pointerDragged(to: start)
        model.pointerUp(at: start)

        model.undo()
        #expect(model.document.commands.isEmpty, "undo should remove the shape, not a no-op resize")
    }

    @Test("Dragging an arrow's end moves that end, not the whole arrow")
    func arrowEndHandleMovesTheTip() {
        let model = makeModel()
        let arrow = AnnotationCommand.arrow(ArrowSpec(
            start: CGPoint(x: 40, y: 40),
            end: CGPoint(x: 200, y: 40)
        ))
        model.document.add(arrow)
        model.document.selection = [arrow.id]

        dragHandle(model, .pathEnd, by: CGSize(width: 40, height: 30))

        guard case let .arrow(spec) = model.document.command(arrow.id) else {
            Issue.record("expected an arrow")
            return
        }
        #expect(spec.start == CGPoint(x: 40, y: 40))
        #expect(spec.end == CGPoint(x: 240, y: 70))
    }

    @Test("⇧ on a corner holds the aspect")
    func shiftLocksAspect() throws {
        let model = makeModel()
        let id = addShape(model, size: CGSize(width: 80, height: 40))

        dragHandle(
            model,
            .box(.bottomTrailing),
            by: CGSize(width: 40, height: 0),
            modifiers: .constrain
        )

        let grown = try #require(rect(model, id))
        #expect(abs(grown.width / grown.height - 2) < 0.01, "80×40 must stay 2:1")
        #expect(grown.origin == CGPoint(x: 100, y: 100))
    }

    @Test("A corner click on an unselected shape resizes it, rather than only selecting")
    func cornerClickSelectsAndResizes() throws {
        let model = makeModel()
        let id = addShape(model)
        let command = try #require(model.document.command(id))
        let start = try #require(SelectionResizer.anchors(for: [command]).first { $0.0 == .box(.bottomTrailing) }?.1)
        model.document.selection = []

        model.pointerDown(at: start)
        model.pointerDragged(to: CGPoint(x: start.x + 40, y: start.y + 20))
        model.pointerUp(at: CGPoint(x: start.x + 40, y: start.y + 20))

        let grown = try #require(rect(model, id))
        #expect(grown.origin == CGPoint(x: 100, y: 100), "a corner click must not move the shape")
        #expect(grown.size == CGSize(width: 100, height: 60))
    }

    @Test("Clicking just inside a selected corner resizes, not moves")
    func clickNearCornerResizes() throws {
        let model = makeModel()
        let id = addShape(model)
        let corner = handlePoint(model, .box(.bottomTrailing))
        let justInside = CGPoint(x: corner.x - 6, y: corner.y - 6)

        model.pointerDown(at: justInside)
        model.pointerDragged(to: CGPoint(x: justInside.x + 40, y: justInside.y + 20))
        model.pointerUp(at: CGPoint(x: justInside.x + 40, y: justInside.y + 20))

        let grown = try #require(rect(model, id))
        #expect(grown.origin == CGPoint(x: 100, y: 100))
        #expect(grown.width > 60)
        #expect(grown.height > 40)
    }
}
