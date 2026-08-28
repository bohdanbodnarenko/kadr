import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import EditorUI

/// Composing several captures in the editor (docs/03 §3 P2, docs/06 M24).
@MainActor
@Suite("Composition")
struct EditorCompositionTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 400, height: 300), scale: 2)
        ))
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    @Test("Dropping an image adds it and selects it")
    func insertSelects() throws {
        let model = makeModel()
        let id = try #require(model.insertImage(
            pngData: png,
            pixelSize: CGSize(width: 200, height: 100),
            at: CGPoint(x: 200, y: 150)
        ))
        #expect(model.insertedImages.count == 1)
        #expect(model.selection == [id])
        #expect(model.selectedImage?.pngData == png)
    }

    @Test("Several images stack, newest on top")
    func severalImages() {
        let model = makeModel()
        for index in 0 ..< 3 {
            model.insertImage(
                pngData: Data([UInt8(index)]),
                pixelSize: CGSize(width: 100, height: 100),
                at: CGPoint(x: 100 + index * 20, y: 100)
            )
        }
        #expect(model.insertedImages.count == 3)
        #expect(model.insertedImages.last?.pngData == Data([2]))
    }

    @Test("Empty data or a zero-sized image inserts nothing")
    func refusesNonsense() {
        let model = makeModel()
        #expect(model.insertImage(pngData: Data(), pixelSize: CGSize(width: 10, height: 10), at: .zero) == nil)
        #expect(model.insertImage(pngData: png, pixelSize: .zero, at: .zero) == nil)
        #expect(model.insertedImages.isEmpty)
    }

    @Test("An inserted image can be moved like any other annotation")
    func movesWithSelection() throws {
        let model = makeModel()
        model.insertImage(pngData: png, pixelSize: CGSize(width: 100, height: 100), at: CGPoint(x: 200, y: 150))
        let before = try #require(model.selectedImage).rect

        model.nudgeSelection(dx: 10, dy: -5)
        let after = try #require(model.selectedImage).rect
        #expect(after.minX == before.minX + 10)
        #expect(after.minY == before.minY - 5)
    }

    @Test("The inspector's edits land on the selected image")
    func inspectorEdits() throws {
        let model = makeModel()
        model.insertImage(pngData: png, pixelSize: CGSize(width: 100, height: 100), at: CGPoint(x: 200, y: 150))

        model.updateSelectedImage { $0.opacity = 0.5 }
        model.updateSelectedImage { $0.cornerRadius = 12 }
        model.updateSelectedImage { $0.hasShadow = false }
        model.updateSelectedImage { $0.scale(to: 2) }

        let spec = try #require(model.selectedImage)
        #expect(spec.opacity == 0.5)
        #expect(spec.cornerRadius == 12)
        #expect(!spec.hasShadow)
        #expect(spec.scaleFactor == 2)
    }

    @Test("Each edit is its own undo step")
    func editsAreUndoable() throws {
        let model = makeModel()
        model.insertImage(pngData: png, pixelSize: CGSize(width: 100, height: 100), at: CGPoint(x: 200, y: 150))
        model.updateSelectedImage { $0.opacity = 0.4 }
        model.undo()
        #expect(try #require(model.selectedImage).opacity == 1)
        model.undo()
        #expect(model.insertedImages.isEmpty)
    }

    @Test("With nothing selected there is no image to edit")
    func noSelectionNoEdit() {
        let model = makeModel()
        model.insertImage(pngData: png, pixelSize: CGSize(width: 100, height: 100), at: CGPoint(x: 200, y: 150))
        model.selection = []
        #expect(model.selectedImage == nil)

        let before = model.document.commands
        model.updateSelectedImage { $0.opacity = 0.1 }
        #expect(model.document.commands == before)
    }

    @Test("Deleting the selection removes the image")
    func deleteRemoves() {
        let model = makeModel()
        model.insertImage(pngData: png, pixelSize: CGSize(width: 100, height: 100), at: CGPoint(x: 200, y: 150))
        model.deleteSelection()
        #expect(model.insertedImages.isEmpty)
    }
}
