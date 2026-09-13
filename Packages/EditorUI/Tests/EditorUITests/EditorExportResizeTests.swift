import AnnotationModel
import CoreGraphics
import Testing
@testable import EditorUI

@MainActor
@Suite("Export resize")
struct EditorExportResizeTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
    }

    @Test("Native size is the capture's pixel size")
    func nativeSizeMatchesCapture() {
        let model = makeModel()
        #expect(model.nativeExportPixelSize == CGSize(width: 1600, height: 1200))
        #expect(model.exportPixelSize == model.nativeExportPixelSize)
    }

    @Test("50% halves the export")
    func halfScaleHalvesPixels() {
        let model = makeModel()
        model.setExportScale(0.5)
        #expect(model.exportPixelSize == CGSize(width: 800, height: 600))
    }

    @Test("Retina 1× uses the capture scale")
    func retinaOneToOne() {
        let model = makeModel()
        #expect(model.canScaleExportToOneToOne)
        model.scaleExportToOneToOne()
        #expect(model.exportPixelSize == CGSize(width: 800, height: 600))
    }

    @Test("Width field keeps aspect")
    func widthKeepsAspect() {
        let model = makeModel()
        model.setExportPixelWidth(800)
        #expect(model.exportPixelSize.width == 800)
        #expect(model.exportPixelSize.height == 600)
    }
}
