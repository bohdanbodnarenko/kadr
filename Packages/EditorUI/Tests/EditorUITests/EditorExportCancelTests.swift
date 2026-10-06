import AnnotationModel
import CoreGraphics
import Testing
@testable import EditorUI

/// Cancel on the editor's export chip (docs/18 §4.1 P3).
@MainActor
@Suite("Editor export cancel")
struct EditorExportCancelTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
    }

    @Test("Cancel stops the render and clears the chip")
    func cancelStopsAndClears() {
        let model = makeModel()
        var cancelled = false
        model.beginExport(.save)
        model.exportCancellation = { cancelled = true }
        #expect(model.canCancelExport)

        model.cancelExport()

        #expect(cancelled)
        #expect(model.runningExport == nil)
        #expect(!model.canCancelExport)
        #expect(model.exportFailure == nil, "a cancel is not a failure")
    }

    @Test("An export with no way to stop offers no Cancel")
    func noHandlerNoCancel() {
        let model = makeModel()
        model.beginExport(.copy)
        #expect(!model.canCancelExport)
    }

    @Test("Finishing forgets the handler, so a later Cancel cannot reach a finished render")
    func finishForgetsHandler() {
        let model = makeModel()
        var cancelled = false
        model.beginExport(.save)
        model.exportCancellation = { cancelled = true }
        model.endExport()

        model.cancelExport()

        #expect(!cancelled)
    }
}
