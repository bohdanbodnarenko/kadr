import AnnotationModel
import CoreGraphics
import Shared
import Testing
@testable import EditorUI

@MainActor
@Suite("Smart highlighter")
struct EditorHighlighterTests {
    private func makeModel() -> EditorDocumentModel {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 400, height: 200), scale: 2)
        ))
        model.tool = .highlighter
        return model
    }

    private let word = CGRect(x: 40, y: 80, width: 80, height: 20)
    private let other = CGRect(x: 200, y: 80, width: 60, height: 18)

    @Test("A click on a recognized word places a highlight sized to it")
    func clickSnapsToWord() throws {
        let model = makeModel()
        model.loadHighlightLayout(from: VisionAnalysis(words: [
            RecognizedWord(
                text: "Hello",
                boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.1)
            )
        ]))

        let box = try #require(model.highlightTarget(at: CGPoint(x: 80, y: 90)))
        model.pointerDown(at: CGPoint(x: 80, y: 90))
        model.pointerUp(at: CGPoint(x: 80, y: 90))

        let command = try #require(model.document.commands.first)
        guard case let .highlighter(spec) = command else {
            Issue.record("expected a highlighter stroke")
            return
        }
        #expect(spec.points.count == 2)
        #expect(spec.points[0].x == box.minX)
        #expect(spec.points[1].x == box.maxX)
        #expect(spec.points[0].y == box.midY)
        #expect(spec.stroke.width >= box.height)
        #expect(model.tool == .highlighter, "highlighter stays armed")
    }

    @Test("Command disables snapping so a click on a word draws nothing")
    func commandDisablesSnap() {
        let model = makeModel()
        model.highlightBoxes = [word]
        model.pointerDown(at: CGPoint(x: 50, y: 90), modifiers: .extendSelection)
        model.pointerUp(at: CGPoint(x: 50, y: 90), modifiers: .extendSelection)
        #expect(model.document.commands.isEmpty)
        #expect(model.highlightTarget(at: CGPoint(x: 50, y: 90), modifiers: .extendSelection) == nil)
    }

    @Test("Dragging past the slop falls through to a freehand stroke")
    func dragBecomesFreehand() throws {
        let model = makeModel()
        model.highlightBoxes = [word]
        model.pointerDown(at: CGPoint(x: 50, y: 90))
        model.pointerDragged(to: CGPoint(x: 120, y: 110))
        model.pointerUp(at: CGPoint(x: 120, y: 110))

        let command = try #require(model.document.commands.first)
        guard case let .highlighter(spec) = command else {
            Issue.record("expected a highlighter stroke")
            return
        }
        #expect(spec.points.first == CGPoint(x: 50, y: 90))
        #expect(spec.points.last == CGPoint(x: 120, y: 110))
    }

    @Test("The smallest box under the pointer wins")
    func prefersSmallerBox() {
        let model = makeModel()
        model.highlightBoxes = [
            CGRect(x: 0, y: 0, width: 400, height: 200),
            word
        ]
        let hit = model.highlightTarget(at: CGPoint(x: 50, y: 90))
        #expect(hit == word)
    }

    @Test("Hover tracks the word under the pointer")
    func hoverTracksWord() {
        let model = makeModel()
        model.highlightBoxes = [word, other]
        model.pointerMoved(to: CGPoint(x: 50, y: 90))
        #expect(model.hoveredHighlightBox == word)
        model.pointerMoved(to: CGPoint(x: 10, y: 10))
        #expect(model.hoveredHighlightBox == nil)
    }
}
