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

/// Editing text where it sits (docs/09 U1.8).
///
/// The overlay itself needs a window; what is testable without one is the model side —
/// that typing is one undo step rather than one per letter, and that an annotation left
/// empty does not survive.
@MainActor
@Suite("In-place text editing")
struct EditorTextEditingTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
    }

    @discardableResult
    private func addText(_ model: EditorDocumentModel, _ string: String = "Hello") -> AnnotationID {
        let command = AnnotationCommand.text(TextSpec(
            string: string,
            rect: CGRect(x: 40, y: 40, width: 200, height: 40)
        ))
        model.document.add(command)
        return command.id
    }

    private func text(_ model: EditorDocumentModel, _ id: AnnotationID) -> String? {
        guard case let .text(spec)? = model.document.command(id) else { return nil }
        return spec.string
    }

    /// A typed sentence is one undo step. One per keystroke would swallow the whole stack
    /// on a caption — the same failure the pointer drag had (docs/07 C2).
    @Test("Typing a word is one undo step")
    func typingIsOneStep() {
        let model = makeModel()
        let id = addText(model, "H")

        for string in ["He", "Hel", "Hell", "Hello", "Hello there"] {
            model.updateText(id, string: string)
        }
        model.commitTextEdit(id)
        #expect(text(model, id) == "Hello there")

        model.undo()
        #expect(text(model, id) == "H", "the whole typing run should be one step")
    }

    @Test("The document follows every keystroke while typing")
    func documentFollowsTyping() {
        let model = makeModel()
        let id = addText(model, "")

        model.updateText(id, string: "Ka")
        #expect(text(model, id) == "Ka", "the canvas draws from the document, so it must be current")
        model.updateText(id, string: "Kadr")
        #expect(text(model, id) == "Kadr")
        model.commitTextEdit(id)
    }

    /// An annotation the user opened and left empty is one they decided against.
    @Test("An annotation left empty is removed on commit", arguments: ["", "   ", "\n"])
    func emptyIsRemoved(string: String) {
        let model = makeModel()
        let id = addText(model, "Hello")

        model.updateText(id, string: string)
        model.commitTextEdit(id)
        #expect(model.document.command(id) == nil)
    }

    @Test("An annotation with text survives the commit")
    func nonEmptySurvives() {
        let model = makeModel()
        let id = addText(model, "Hello")

        model.updateText(id, string: "Still here")
        model.commitTextEdit(id)
        #expect(text(model, id) == "Still here")
    }

    @Test("Committing without having typed leaves history alone")
    func commitWithoutTyping() {
        let model = makeModel()
        let id = addText(model, "Hello")

        model.commitTextEdit(id)
        model.undo()
        #expect(model.document.command(id) == nil, "undo should remove the annotation itself")
    }

    @Test("Typing into an annotation that has gone is harmless")
    func typingIntoNothing() {
        let model = makeModel()
        model.updateText(AnnotationID(), string: "Hello")
        model.commitTextEdit(AnnotationID())
        #expect(model.document.commands.isEmpty)
    }
}

/// The crop's ratio and canvas controls (docs/09 U1.8).
@MainActor
@Suite("Editor crop")
struct EditorCropTests {
    private func makeModel() -> EditorDocumentModel {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        model.document.setCrop(CropSpec(rect: CGRect(x: 100, y: 100, width: 400, height: 300)))
        return model
    }

    /// A ratio that only takes effect on the *next* drag is a setting that appears to have
    /// done nothing.
    @Test("Choosing a ratio reshapes the crop immediately")
    func choosingAratioReshapes() throws {
        let model = makeModel()
        model.applyCropAspect(.square)

        let rect = try #require(model.document.crop?.rect)
        #expect(abs(rect.width - rect.height) < 0.5, "\(rect) is not square")
    }

    @Test("The ratio is remembered for the next capture")
    func ratioIsRemembered() {
        let model = makeModel()
        model.applyCropAspect(.sixteenNine)
        #expect(model.cropAspect == .sixteenNine)
    }

    @Test("Free leaves the crop alone")
    func freeLeavesItAlone() throws {
        let model = makeModel()
        let before = try #require(model.document.crop?.rect)
        model.applyCropAspect(.free)
        #expect(model.document.crop?.rect == before)
    }

    @Test("A bounded crop stays inside the capture")
    func boundedCropStaysInside() throws {
        let model = makeModel()
        model.applyCropAspect(.nineSixteen)

        let rect = try #require(model.document.crop?.rect)
        #expect(model.document.baseImage.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect))
    }

    /// Expand-canvas is the absence of bounds, so the crop may then leave the image.
    @Test("Allowing the canvas to grow lets the crop leave the image")
    func expandCanvasReleasesTheBounds() {
        let model = makeModel()
        model.setCropCanExpandCanvas(true)
        #expect(model.document.crop?.canExpandCanvas == true)

        model.document.setCrop(CropSpec(
            rect: CGRect(x: -50, y: -50, width: 900, height: 700),
            canExpandCanvas: true
        ))
        #expect(model.document.canvasRect.width > 800)
    }

    @Test("Turning it off brings the crop back inside")
    func turningOffClampsBack() throws {
        let model = makeModel()
        model.document.setCrop(CropSpec(
            rect: CGRect(x: -50, y: -50, width: 900, height: 700),
            canExpandCanvas: true
        ))
        model.setCropCanExpandCanvas(false)

        let rect = try #require(model.document.crop?.rect)
        #expect(model.document.baseImage.bounds.contains(rect))
    }

    @Test("Resetting removes the crop")
    func resetting() {
        let model = makeModel()
        model.clearCrop()
        #expect(model.document.crop == nil)
    }

    @Test("Dragging inside the capture rubber-bands a crop")
    func interiorDragCreatesACrop() throws {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        model.tool = .crop
        model.pointerDown(at: CGPoint(x: 100, y: 80))
        model.pointerDragged(to: CGPoint(x: 300, y: 280))
        model.pointerUp(at: CGPoint(x: 300, y: 280))

        let rect = try #require(model.document.crop?.rect)
        #expect(abs(rect.minX - 100) < 1)
        #expect(abs(rect.minY - 80) < 1)
        #expect(abs(rect.width - 200) < 1)
        #expect(abs(rect.height - 200) < 1)
        #expect(model.tool == .crop)
    }

    @Test("A click without a drag does not plant a crop")
    func clickDoesNotPlantACrop() {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        model.tool = .crop
        model.pointerDown(at: CGPoint(x: 100, y: 80))
        model.pointerUp(at: CGPoint(x: 100, y: 80))
        #expect(model.document.crop == nil)
    }

    /// Dragging a crop handle is many commits; the whole drag has to be one undo step.
    @Test("A run of crop edits collapses into one undo step")
    func cropEditsCoalesce() {
        let model = makeModel()
        for width in stride(from: 400.0, through: 500.0, by: 10) {
            model.document.setCrop(CropSpec(rect: CGRect(x: 100, y: 100, width: width, height: 300)))
        }
        model.undo()
        #expect(model.document.crop == nil, "the whole drag should be one step")
    }
}
