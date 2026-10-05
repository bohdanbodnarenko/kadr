import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// Moving a selection with the pointer (docs/03 §3, docs/07 C2, docs/09 U0.2).
///
/// This is the coverage gap the review called out. Both halves of C2 are pinned here: the
/// drag must not compound — a 100-point drag moves 100 points, not 100 × the number of
/// mouse-moved events — and one gesture must cost exactly one undo step, or a few seconds
/// of dragging swallows the whole history.
@MainActor
@Suite("Select-mode drag")
struct EditorSelectDragTests {
    private func makeModel() -> EditorDocumentModel {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        model.tool = .select
        return model
    }

    /// A shape at a known origin, already committed to the document.
    ///
    /// Filled, so the whole rectangle is grabbable: an unfilled one is only grabbable on
    /// its edge, which would make these tests about hit-testing rather than about dragging.
    @discardableResult
    private func addShape(
        _ model: EditorDocumentModel,
        at origin: CGPoint = CGPoint(x: 100, y: 100)
    ) -> AnnotationID {
        let command = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(origin: origin, size: CGSize(width: 60, height: 40)),
            fill: FillStyle(color: .white)
        ))
        model.document.add(command)
        return command.id
    }

    private func rect(_ model: EditorDocumentModel, _ id: AnnotationID) -> CGRect? {
        guard case let .shape(spec) = model.document.command(id) else { return nil }
        return spec.rect
    }

    /// Walks the pointer from `from` to `to` in `steps` events, as a real drag does.
    private func drag(
        _ model: EditorDocumentModel,
        from start: CGPoint,
        to end: CGPoint,
        steps: Int
    ) {
        model.pointerDown(at: start)
        for step in 1 ... steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            model.pointerDragged(to: CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            ))
        }
        model.pointerUp(at: end)
    }

    // MARK: - The move lands where the pointer did

    /// The compounding bug in one assertion: with the old code a 10-event drag moved ten
    /// times too far, so the event count is the axis that matters.
    @Test("A drag moves by the pointer's travel, whatever the event count", arguments: [1, 2, 10, 60])
    func dragDoesNotCompound(steps: Int) throws {
        let model = makeModel()
        let id = addShape(model)

        drag(model, from: CGPoint(x: 110, y: 110), to: CGPoint(x: 210, y: 160), steps: steps)

        let moved = try #require(rect(model, id))
        #expect(moved.origin == CGPoint(x: 200, y: 150), "a 100×50 drag must move 100×50")
    }

    @Test("Dragging back to where it started leaves the annotation where it started")
    func roundTripDragIsIdentity() throws {
        let model = makeModel()
        let id = addShape(model)
        let before = try #require(rect(model, id))

        model.pointerDown(at: CGPoint(x: 110, y: 110))
        model.pointerDragged(to: CGPoint(x: 400, y: 300))
        model.pointerDragged(to: CGPoint(x: 250, y: 90))
        model.pointerDragged(to: CGPoint(x: 110, y: 110))
        model.pointerUp(at: CGPoint(x: 110, y: 110))

        #expect(rect(model, id) == before)
    }

    @Test("Every selected annotation moves by the same amount")
    func multiSelectionMovesTogether() throws {
        let model = makeModel()
        let first = addShape(model, at: CGPoint(x: 100, y: 100))
        let second = addShape(model, at: CGPoint(x: 300, y: 220))
        model.selectAll()

        // Grabbing an already-selected annotation keeps the whole selection, which is
        // what makes a multi-annotation drag possible at all.
        model.pointerDown(at: CGPoint(x: 110, y: 110))
        model.pointerDragged(to: CGPoint(x: 130, y: 140))
        model.pointerUp(at: CGPoint(x: 130, y: 140))

        #expect(try #require(rect(model, first)).origin == CGPoint(x: 120, y: 130))
        #expect(try #require(rect(model, second)).origin == CGPoint(x: 320, y: 250))
    }

    // MARK: - One gesture, one undo step

    @Test("A whole drag is a single undo step, however many events it took", arguments: [2, 30, 120])
    func oneDragIsOneUndoStep(steps: Int) throws {
        let model = makeModel()
        let id = addShape(model)
        let before = try #require(rect(model, id))

        drag(model, from: CGPoint(x: 110, y: 110), to: CGPoint(x: 210, y: 160), steps: steps)
        #expect(rect(model, id)?.origin == CGPoint(x: 200, y: 150))

        model.undo()
        #expect(rect(model, id) == before, "one undo must put the drag back")

        // And the step before that is the shape's creation, not another slice of the drag.
        model.undo()
        #expect(model.document.commands.isEmpty)
    }

    /// docs/03 §3 asks for a usable undo depth of at least 100; the review's failure mode
    /// was one drag consuming all of it.
    @Test("Fifty drags leave fifty undo steps")
    func fiftyDragsLeaveFiftyUndoSteps() throws {
        let model = makeModel()
        let id = addShape(model)

        for step in 0 ..< 50 {
            let origin = CGPoint(x: 110 + CGFloat(step), y: 110)
            drag(model, from: origin, to: CGPoint(x: origin.x + 1, y: 110), steps: 8)
        }
        #expect(try #require(rect(model, id)).origin == CGPoint(x: 150, y: 100))

        for _ in 0 ..< 50 {
            model.undo()
        }
        #expect(try #require(rect(model, id)).origin == CGPoint(x: 100, y: 100))
    }

    @Test("A click that does not move costs no undo step")
    func clickWithoutMovingIsNotAnEdit() {
        let model = makeModel()
        let id = addShape(model)

        model.pointerDown(at: CGPoint(x: 110, y: 110))
        model.pointerDragged(to: CGPoint(x: 110, y: 110))
        model.pointerUp(at: CGPoint(x: 110, y: 110))

        model.undo()
        #expect(model.document.commands.isEmpty, "undo should remove the shape, not a no-op move")
    }

    @Test("Redo replays the whole drag, not one frame of it")
    func redoReplaysTheWholeDrag() throws {
        let model = makeModel()
        let id = addShape(model)

        drag(model, from: CGPoint(x: 110, y: 110), to: CGPoint(x: 210, y: 110), steps: 20)
        model.undo()
        model.redo()

        #expect(try #require(rect(model, id)).origin == CGPoint(x: 200, y: 100))
    }

    // MARK: - The other pointer paths still behave

    @Test("Arrow-key nudges are still relative, and a run of them undoes as one (docs/18 T-ED-12)")
    func nudgeIsUnaffected() throws {
        let model = makeModel()
        let id = addShape(model)

        model.selectAll()
        model.nudgeSelection(dx: 5, dy: 0)
        model.nudgeSelection(dx: 5, dy: 0)
        #expect(try #require(rect(model, id)).origin == CGPoint(x: 110, y: 100))

        model.undo()
        #expect(try #require(rect(model, id)).origin == CGPoint(x: 100, y: 100))
    }

    @Test("A marquee drag over empty canvas selects and edits nothing")
    func marqueeDoesNotMove() throws {
        let model = makeModel()
        let id = addShape(model)
        let before = try #require(rect(model, id))

        // Start well clear of the shape so the drag is a marquee, then sweep over it.
        drag(model, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 400, y: 400), steps: 10)

        #expect(rect(model, id) == before, "a marquee selects; it must not move anything")
        #expect(model.selection == [id])

        model.undo()
        #expect(model.document.commands.isEmpty, "the marquee left no edit to undo")
    }

    @Test("Drawing a shape is still one undo step")
    func drawingIsStillOneStep() {
        let model = makeModel()
        model.tool = .shape

        model.pointerDown(at: CGPoint(x: 10, y: 10))
        for step in 1 ... 20 {
            model.pointerDragged(to: CGPoint(x: 10 + CGFloat(step) * 5, y: 10 + CGFloat(step) * 3))
        }
        model.pointerUp(at: CGPoint(x: 110, y: 70))

        #expect(model.document.commands.count == 1)
        model.undo()
        #expect(model.document.commands.isEmpty)
    }
}
