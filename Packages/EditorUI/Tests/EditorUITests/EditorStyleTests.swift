import AnnotationModel
import CoreGraphics
import Testing
@testable import EditorUI

@MainActor
@Suite("Editor style editing")
struct EditorStyleTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 800, height: 600), scale: 2)
        ))
    }

    @Test("Changing colour recolours the selection, not just the next drawing")
    func applyColorUpdatesSelection() throws {
        let model = makeModel()
        model.tool = .arrow
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerDragged(to: CGPoint(x: 80, y: 40))
        model.pointerUp(at: CGPoint(x: 80, y: 40))

        model.applyColor(.black)

        guard case let .arrow(spec) = try #require(model.document.commands.first) else { return }
        #expect(spec.stroke.color == .black)
        #expect(model.styleMemory.stroke(for: .arrow).color == .black)
    }

    @Test("Changing width updates the selected stroke")
    func applyWidthUpdatesSelection() throws {
        let model = makeModel()
        model.tool = .line
        model.pointerDown(at: CGPoint(x: 0, y: 0))
        model.pointerDragged(to: CGPoint(x: 40, y: 0))
        model.pointerUp(at: CGPoint(x: 40, y: 0))

        model.applyStrokeWidth(10)

        guard case let .line(spec) = try #require(model.document.commands.first) else { return }
        #expect(spec.stroke.width == 10)
    }

    @Test("A shape can be switched from a rectangle to an ellipse after it is drawn")
    func applyShapeKindUpdatesSelection() throws {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 40, y: 40))
        model.pointerUp(at: CGPoint(x: 40, y: 40))

        model.applyShapeKind(.ellipse)

        guard case let .shape(spec) = try #require(model.document.commands.first) else { return }
        #expect(spec.kind == .ellipse)
        #expect(model.styleMemory.lastShapeKind == .ellipse)
    }

    @Test("Duplicate offsets the copy and selects it")
    func duplicateOffsetsAndSelects() throws {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 40, y: 30))
        model.pointerUp(at: CGPoint(x: 40, y: 30))

        let originalID = try #require(model.document.commands.first?.id)
        model.duplicateSelection()

        #expect(model.document.commands.count == 2)
        #expect(!model.selection.contains(originalID))
        guard case let .shape(original) = model.document.commands[0],
              case let .shape(copy) = model.document.commands[1]
        else {
            Issue.record("expected two shapes")
            return
        }
        #expect(copy.id != original.id)
        #expect(copy.rect.origin.x == original.rect.origin.x + 16)
        #expect(copy.rect.origin.y == original.rect.origin.y + 16)
    }

    @Test("A highlighter keeps its translucency when recolored")
    func highlighterKeepsAlpha() throws {
        let model = makeModel()
        model.tool = .highlighter
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 20, y: 0))
        model.pointerUp(at: CGPoint(x: 20, y: 0))

        model.applyColor(.annotationRed)

        guard case let .highlighter(spec) = try #require(model.document.commands.first) else { return }
        #expect(abs(spec.stroke.color.alpha - 0.4) < 0.001)
    }

    @Test("Changing blur vs pixelate updates the selected redaction")
    func applyRedactionStyleUpdatesSelection() throws {
        let model = makeModel()
        model.tool = .redaction
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 80, y: 60))
        model.pointerUp(at: CGPoint(x: 80, y: 60))

        model.applyRedactionStyle(.defaultPixelate)

        guard case let .redaction(spec) = try #require(model.document.commands.first) else { return }
        #expect(spec.style.isPixelate)
        #expect(model.styleMemory.lastRedactionStyle.isPixelate)

        model.applyRedactionStyle(spec.style.withDensity(0.8))
        guard case let .redaction(stronger) = try #require(model.document.commands.first) else { return }
        #expect(abs(stronger.style.density - 0.8) < 0.001)
    }
}
