import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// Drawing an arrow onto something (docs/09 U1.7).
///
/// The model tests cover the geometry; these cover the gesture — that dropping an arrow on
/// a shape binds it, that dropping it on nothing does not, and that dragging the shape
/// afterwards takes the arrow with it.
@MainActor
@Suite("Editor arrow bindings")
struct EditorArrowBindingTests {
    private func makeModel() -> EditorDocumentModel {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        model.tool = .arrow
        return model
    }

    /// A filled shape, so the whole rectangle is grabbable rather than only its edge.
    @discardableResult
    private func addShape(_ model: EditorDocumentModel, at origin: CGPoint) -> AnnotationID {
        let command = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(origin: origin, size: CGSize(width: 100, height: 60)),
            fill: FillStyle(color: .white)
        ))
        model.document.add(command)
        return command.id
    }

    private func drawArrow(_ model: EditorDocumentModel, from start: CGPoint, to end: CGPoint) {
        model.tool = .arrow
        model.pointerDown(at: start)
        model.pointerDragged(to: end)
        model.pointerUp(at: end)
    }

    private func lastArrow(_ model: EditorDocumentModel) -> ArrowSpec? {
        model.document.commands.reversed().compactMap { command in
            if case let .arrow(spec) = command {
                return spec
            }
            return nil
        }.first
    }

    @Test("An arrow dropped on a shape binds to it")
    func droppingBinds() throws {
        let model = makeModel()
        let target = addShape(model, at: CGPoint(x: 300, y: 300))
        drawArrow(model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 330))

        let arrow = try #require(lastArrow(model))
        #expect(arrow.endBinding?.targetID == target)
        #expect(arrow.startBinding == nil, "the tail was over nothing")
    }

    @Test("An arrow drawn between two shapes binds both ends")
    func bothEndsBind() throws {
        let model = makeModel()
        let first = addShape(model, at: CGPoint(x: 50, y: 50))
        let second = addShape(model, at: CGPoint(x: 400, y: 400))
        drawArrow(model, from: CGPoint(x: 100, y: 80), to: CGPoint(x: 450, y: 430))

        let arrow = try #require(lastArrow(model))
        #expect(arrow.startBinding?.targetID == first)
        #expect(arrow.endBinding?.targetID == second)
    }

    @Test("An arrow drawn over empty canvas binds nothing")
    func emptyCanvasDoesNotBind() throws {
        let model = makeModel()
        drawArrow(model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 200, y: 200))

        let arrow = try #require(lastArrow(model))
        #expect(arrow.startBinding == nil)
        #expect(arrow.endBinding == nil)
    }

    /// An arrow bound to the beautify backdrop would follow a background rather than a
    /// thing, so canvas chrome is not a binding target.
    @Test("Canvas chrome is not a binding target")
    func chromeIsNotATarget() throws {
        let model = makeModel()
        model.applyBeautify(.cleanWhite)
        drawArrow(model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 200, y: 200))

        let arrow = try #require(lastArrow(model))
        #expect(arrow.endBinding == nil)
    }

    @Test("An arrow does not bind to itself")
    func noSelfBinding() throws {
        let model = makeModel()
        drawArrow(model, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 120, y: 120))

        let arrow = try #require(lastArrow(model))
        #expect(arrow.startBinding?.targetID != arrow.id)
        #expect(arrow.endBinding?.targetID != arrow.id)
    }

    /// The payoff: moving the shape moves the arrow, with nothing having to remember which
    /// arrows point at it.
    @Test("Dragging the target takes the arrow with it")
    func draggingTheTargetMovesTheArrow() throws {
        let model = makeModel()
        addShape(model, at: CGPoint(x: 300, y: 300))
        drawArrow(model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 330))

        let before = try #require(resolvedArrow(model)).end

        // Grabbed low in the shape, clear of the arrow itself — clicking where the two
        // overlap would pick up the arrow, which is a different test.
        model.tool = .select
        model.pointerDown(at: CGPoint(x: 320, y: 350))
        model.pointerDragged(to: CGPoint(x: 520, y: 350))
        model.pointerUp(at: CGPoint(x: 520, y: 350))

        let after = try #require(resolvedArrow(model)).end
        #expect(after.x > before.x + 150, "the arrow should have followed the shape")
    }

    @Test("Deleting the target unbinds the arrow rather than moving it")
    func deletingTheTargetUnbinds() throws {
        let model = makeModel()
        let target = addShape(model, at: CGPoint(x: 300, y: 300))
        drawArrow(model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 330))
        let before = try #require(resolvedArrow(model)).end

        model.document.remove([target])

        let arrow = try #require(lastArrow(model))
        #expect(arrow.endBinding == nil)
        #expect(abs(arrow.end.x - before.x) < 0.001, "and it should not have jumped")
    }

    @Test("Binding survives undo and redo of the drawing")
    func undoRedo() throws {
        let model = makeModel()
        let target = addShape(model, at: CGPoint(x: 300, y: 300))
        drawArrow(model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 330))

        model.undo()
        #expect(lastArrow(model) == nil)

        model.redo()
        #expect(try #require(lastArrow(model)).endBinding?.targetID == target)
    }

    /// Bindings are by identity, so bringing a shape to the front cannot detach it.
    @Test("Reordering the shape does not detach the arrow")
    func reordering() throws {
        let model = makeModel()
        let target = addShape(model, at: CGPoint(x: 300, y: 300))
        drawArrow(model, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 330))
        let before = try #require(resolvedArrow(model)).end

        model.document.selection = [target]
        model.sendSelectionToBack()

        #expect(try #require(lastArrow(model)).endBinding?.targetID == target)
        let after = try #require(resolvedArrow(model)).end
        #expect(abs(after.x - before.x) < 0.001)
    }

    private func resolvedArrow(_ model: EditorDocumentModel) -> ArrowSpec? {
        model.document.resolvedCommands.reversed().compactMap { command in
            if case let .arrow(spec) = command {
                return spec
            }
            return nil
        }.first
    }
}
