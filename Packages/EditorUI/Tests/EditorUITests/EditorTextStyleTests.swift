import AnnotationModel
import Foundation
import Testing
@testable import EditorUI

@MainActor
@Suite("Editor text style presets")
struct EditorTextStyleTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
    }

    private func placeText(_ model: EditorDocumentModel) throws -> AnnotationID {
        model.tool = .text
        model.pointerDown(at: CGPoint(x: 40, y: 40))
        model.pointerDragged(to: CGPoint(x: 180, y: 90))
        model.pointerUp(at: CGPoint(x: 180, y: 90))
        return try #require(model.document.commands.first?.id)
    }

    @Test("All seven presets update selected text through applyTextStyle")
    func presetsRewriteSelectedText() throws {
        let model = makeModel()
        let id = try placeText(model)
        model.document.selection = [id]

        for preset in TextStyle.presets {
            model.applyTextStyle(preset.style)
            guard case let .text(spec) = model.document.command(id) else {
                Issue.record("expected text command")
                continue
            }
            #expect(spec.style == preset.style)
            #expect(model.styleMemory.lastTextStyle == preset.style)
        }
        #expect(TextStyle.presets.count == 7)
    }

    @Test("Custom font, weight, size, and pill update the selection")
    func customPropertiesRewriteSelectedText() throws {
        let model = makeModel()
        let id = try placeText(model)
        model.document.selection = [id]

        var custom = TextStyle(
            fontName: "Menlo",
            fontSize: 28,
            isBold: false,
            color: .black,
            backgroundColor: .annotationRed,
            alignment: .center
        )
        model.applyTextStyle(custom)

        guard case let .text(spec) = model.document.command(id) else {
            Issue.record("expected text command")
            return
        }
        #expect(spec.style.fontName == "Menlo")
        #expect(spec.style.fontSize == 28)
        #expect(spec.style.isBold == false)
        #expect(spec.style.color == .black)
        #expect(spec.style.backgroundColor == .annotationRed)
        #expect(spec.style.alignment == .center)
    }
}
