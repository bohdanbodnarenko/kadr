import AnnotationModel
import CoreGraphics
import Testing
@testable import EditorUI

/// Feedback for a drag on a locked annotation (docs/18 T-ED-12).
@MainActor
@Suite("Locked object notice")
struct EditorLockedNoticeTests {
    private func makeModel() -> (EditorDocumentModel, AnnotationCommand) {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
        let shape = AnnotationCommand.shape(ShapeSpec(rect: CGRect(x: 100, y: 100, width: 80, height: 80)))
        model.document.add(shape)
        model.tool = .select
        model.isCanvasLocked = true
        return (model, shape)
    }

    @Test("Dragging a locked annotation leaves it in place and says why")
    func dragShowsNotice() throws {
        let (model, shape) = makeModel()
        let before = AnnotationHitTesting.boundingBox(of: shape)

        model.pointerDown(at: CGPoint(x: 100, y: 140))
        model.pointerDragged(to: CGPoint(x: 300, y: 300))
        model.pointerUp(at: CGPoint(x: 300, y: 300))

        let after = try #require(model.document.commands.first)
        #expect(AnnotationHitTesting.boundingBox(of: after) == before)
        #expect(model.showsLockedNotice)
        #expect(model.marquee == nil)
    }

    @Test("A drag on empty canvas while locked still draws a marquee, with no notice")
    func emptyCanvasDragIsMarquee() {
        let (model, _) = makeModel()
        model.pointerDown(at: CGPoint(x: 500, y: 500))
        model.pointerDragged(to: CGPoint(x: 600, y: 560))
        #expect(!model.showsLockedNotice)
        model.pointerUp(at: CGPoint(x: 600, y: 560))
    }

    @Test("Unlocking clears the notice")
    func unlockClears() {
        let (model, _) = makeModel()
        model.showsLockedNotice = true
        model.isCanvasLocked = false
        #expect(!model.showsLockedNotice)
    }
}
