import AnnotationModel
import CoreGraphics
import Foundation
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

    @Test("Changing color recolors the selection, not just the next drawing")
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

    @Test("Paste inserts a new-identity copy of encoded annotations")
    func pasteEncodedInsertsCopy() throws {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 40, y: 30))
        model.pointerUp(at: CGPoint(x: 40, y: 30))

        let data = try #require(model.encodedSelection())
        #expect(model.pasteEncoded(data))
        #expect(model.document.commands.count == 2)
        #expect(model.encodedSelection() != nil)

        guard case let .shape(original) = model.document.commands[0],
              case let .shape(copy) = model.document.commands[1]
        else {
            Issue.record("expected two shapes")
            return
        }
        #expect(copy.id != original.id)
        #expect(copy.rect.origin.x == original.rect.origin.x + 16)
    }

    @Test("Copy with nothing selected encodes nothing")
    func emptySelectionDoesNotEncode() {
        let model = makeModel()
        #expect(model.encodedSelection() == nil)
        #expect(!model.pasteEncoded(Data("[]".utf8)))
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

    @Test("A filled shape keeps its fill opacity when recolored")
    func recolorPreservesFillOpacity() throws {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 40, y: 30))
        model.pointerUp(at: CGPoint(x: 40, y: 30))

        model.applyShapeFill(.annotationRed.withAlpha(0.6))
        model.applyColor(.black)

        guard case let .shape(spec) = try #require(model.document.commands.first) else { return }
        #expect(spec.stroke.color == .black)
        #expect(abs((spec.fill.color?.alpha ?? 0) - 0.6) < 0.001)
        #expect(spec.fill.color?.red == 0)
    }

    @Test("Fill opacity updates the selected shape and is remembered")
    func applyFillOpacityUpdatesSelection() throws {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 40, y: 30))
        model.pointerUp(at: CGPoint(x: 40, y: 30))

        model.applyShapeFill(.annotationRed.withAlpha(0.25))
        model.applyFillOpacity(0.8)
        model.endInspectorStyleEdit()

        guard case let .shape(spec) = try #require(model.document.commands.first) else { return }
        #expect(abs((spec.fill.color?.alpha ?? 0) - 0.8) < 0.001)
        #expect(abs(model.styleMemory.lastFillOpacity - 0.8) < 0.001)
    }

    @Test("Dragging stroke width coalesces into one undo step")
    func strokeWidthSliderCoalescesUndo() throws {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 40, y: 30))
        model.pointerUp(at: CGPoint(x: 40, y: 30))

        guard case let .shape(original) = try #require(model.document.commands.first) else { return }
        let originalWidth = original.stroke.width

        model.applyStrokeWidth(6)
        model.applyStrokeWidth(10)
        model.applyStrokeWidth(16)
        model.endInspectorStyleEdit()

        guard case let .shape(thick) = try #require(model.document.commands.first) else { return }
        #expect(thick.stroke.width == 16)

        #expect(model.canUndo)
        model.undo()
        guard case let .shape(restored) = try #require(model.document.commands.first) else { return }
        #expect(restored.stroke.width == originalWidth)
        #expect(!model.document.isGestureOpen)
    }

    @Test("Plus and minus keys change the armed tool's stroke width")
    func toolSizeKeysAdjustStroke() {
        let model = makeModel()
        model.tool = .arrow
        let before = model.styleMemory.stroke(for: .arrow).width

        model.adjustToolSize(by: 1)
        #expect(model.styleMemory.stroke(for: .arrow).width == before + 2)

        model.adjustToolSize(by: -1)
        #expect(model.styleMemory.stroke(for: .arrow).width == before)
    }

    @Test("Plus and minus keys change the text tool's font size")
    func toolSizeKeysAdjustText() {
        let model = makeModel()
        model.tool = .text
        let before = model.styleMemory.lastTextStyle.fontSize

        model.adjustToolSize(by: 1)
        #expect(model.styleMemory.lastTextStyle.fontSize == before + 2)

        model.adjustToolSize(by: -1)
        #expect(model.styleMemory.lastTextStyle.fontSize == before)
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
        #expect(spec.style.kind == .pixelate)
        #expect(model.styleMemory.lastRedactionStyle.kind == .pixelate)

        model.applyRedactionStyle(spec.style.withDensity(0.8))
        guard case let .redaction(stronger) = try #require(model.document.commands.first) else { return }
        #expect(abs(stronger.style.density - 0.8) < 0.001)
    }

    // MARK: - docs/18 ED-4: inspector sliders make one undo step per drag

    @Test("Dragging redaction strength coalesces into one undo step")
    func redactionStrengthCoalescesUndo() throws {
        let model = makeModel()
        model.tool = .redaction
        model.pointerDown(at: .zero)
        model.pointerDragged(to: CGPoint(x: 80, y: 60))
        model.pointerUp(at: CGPoint(x: 80, y: 60))
        guard case let .redaction(original) = try #require(model.document.commands.first) else { return }

        for density in stride(from: 0.2, through: 1.0, by: 0.05) {
            model.applyRedactionStyleLive(original.style.withDensity(CGFloat(density)))
        }
        model.endInspectorStyleEdit()

        model.undo()
        guard case let .redaction(restored) = try #require(model.document.commands.first) else { return }
        #expect(restored.style.density == original.style.density)
        model.undo()
        #expect(model.document.commands.isEmpty, "the second undo removes the redaction itself")
    }

    @Test("Dragging image size, opacity and corners coalesces into one undo step each")
    func imageSlidersCoalesceUndo() throws {
        let model = makeModel()
        let id = try #require(model.insertImage(
            pngData: Data([1, 2, 3]),
            pixelSize: CGSize(width: 100, height: 100),
            at: CGPoint(x: 200, y: 200)
        ))
        let original = try #require(model.selectedImage)

        for step in 1 ... 40 {
            model.updateSelectedImageLive { $0.opacity = 1 - Double(step) / 100 }
        }
        model.endInspectorStyleEdit()
        for step in 1 ... 40 {
            model.updateSelectedImageLive { $0.cornerRadius = CGFloat(step) }
        }
        model.endInspectorStyleEdit()
        #expect(model.selectedImage?.cornerRadius == 40)

        model.undo()
        #expect(model.selectedImage?.cornerRadius == original.cornerRadius)
        #expect(abs((model.selectedImage?.opacity ?? 0) - 0.6) < 0.001)
        model.undo()
        #expect(model.selectedImage?.opacity == original.opacity)
        model.undo()
        #expect(model.document.command(id) == nil)
        #expect(!model.document.isGestureOpen)
    }

    @Test("Select with nothing selected has no drawing-tool inspector")
    func selectHasNoInspectedTool() {
        let model = makeModel()
        #expect(model.tool == .select)
        #expect(model.inspectedTool == nil)

        model.tool = .arrow
        #expect(model.inspectedTool == .arrow)
    }

    @Test("Counter size and color rewrite every badge, not just the selection")
    func counterStyleUpdatesAllBadges() {
        let model = makeModel()
        model.tool = .counter
        model.pointerDown(at: CGPoint(x: 20, y: 20))
        model.pointerUp(at: CGPoint(x: 20, y: 20))
        model.pointerDown(at: CGPoint(x: 80, y: 80))
        model.pointerUp(at: CGPoint(x: 80, y: 80))

        model.applyCounterSize(.large)
        model.applyCounterFill(.black)

        let badges = model.document.commands.compactMap { command -> CounterSpec? in
            if case let .counter(spec) = command {
                spec
            } else {
                nil
            }
        }
        #expect(badges.count == 2)
        #expect(badges.allSatisfy { abs($0.radius - CounterBadgeSize.large.radius) < 0.01 })
        #expect(badges.allSatisfy { $0.fill == .black })
        #expect(badges.allSatisfy { $0.textColor == .white })
        #expect(model.styleMemory.lastCounterSize == .large)
        #expect(model.styleMemory.lastCounterFill == .black)
    }

    @Test("The next counter lands at the remembered size and color")
    func counterPlaceUsesRememberedStyle() throws {
        let model = makeModel()
        model.tool = .counter
        model.applyCounterSize(.small)
        model.applyCounterFill(.white)
        model.pointerDown(at: CGPoint(x: 40, y: 40))
        model.pointerUp(at: CGPoint(x: 40, y: 40))

        guard case let .counter(spec) = try #require(model.document.commands.first) else { return }
        #expect(abs(spec.radius - CounterBadgeSize.small.radius) < 0.01)
        #expect(spec.fill == .white)
        #expect(spec.textColor == .black)
    }

    @Test("Size shortcuts step the counter through S–XL")
    func counterSizeShortcuts() {
        let model = makeModel()
        model.tool = .counter
        model.adjustToolSize(by: 1)
        #expect(model.styleMemory.lastCounterSize == .large)
        model.adjustToolSize(by: -2)
        #expect(model.styleMemory.lastCounterSize == .small)
    }
}
