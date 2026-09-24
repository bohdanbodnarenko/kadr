import AnnotationModel
import AppKit
import Testing
@testable import EditorUI

@Suite("Canvas accessibility (T-ED-11)")
struct CanvasAccessibilityTests {
    private static let red = AnnotationColor(red: 1, green: 0, blue: 0)
    private static let blue = AnnotationColor(red: 0.1, green: 0.3, blue: 0.95)

    private static func arrow(_ color: AnnotationColor) -> AnnotationCommand {
        .arrow(ArrowSpec(
            start: .zero,
            end: CGPoint(x: 50, y: 50),
            stroke: StrokeStyle(color: color)
        ))
    }

    @Test(
        "Colour words",
        arguments: [
            (AnnotationColor(red: 1, green: 0, blue: 0), "red"),
            (AnnotationColor(red: 1, green: 0.55, blue: 0), "orange"),
            (AnnotationColor(red: 1, green: 0.9, blue: 0.1), "yellow"),
            (AnnotationColor(red: 0.1, green: 0.8, blue: 0.2), "green"),
            (AnnotationColor(red: 0.1, green: 0.3, blue: 0.95), "blue"),
            (AnnotationColor(red: 0.6, green: 0.2, blue: 0.9), "purple"),
            (AnnotationColor(red: 1, green: 0.3, blue: 0.7), "pink"),
            (AnnotationColor(red: 0, green: 0, blue: 0), "black"),
            (AnnotationColor(red: 1, green: 1, blue: 1), "white"),
            (AnnotationColor(red: 0.5, green: 0.5, blue: 0.5), "gray")
        ]
    )
    func colourWords(color: AnnotationColor, word: String) {
        #expect(CanvasAccessibility.spokenName(of: color) == word)
    }

    @Test("Labels number each kind and name the colour or the text")
    func labels() {
        var text = TextSpec(rect: CGRect(x: 0, y: 0, width: 80, height: 20))
        text.string = "  Click here \n"
        let items = CanvasAccessibility.items(for: [
            Self.arrow(Self.red),
            .text(text),
            Self.arrow(Self.blue),
            .crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        ])
        #expect(items.map(\.label) == ["Arrow 1, red", "Text \u{201C}Click here\u{201D}", "Arrow 2, blue"])
    }

    @Test(
        "Tab walks the annotations and wraps",
        arguments: [
            ([Int](), false, 0),
            ([Int](), true, 2),
            ([0], false, 1),
            ([2], false, 0),
            ([0], true, 2),
            ([0, 1], false, 2),
            ([1, 2], true, 0)
        ]
    )
    func tabOrder(selected: [Int], backward: Bool, expected: Int) {
        let items = CanvasAccessibility.items(for: [Self.arrow(Self.red), Self.arrow(Self.blue), Self.arrow(Self.red)])
        let selection = Set(selected.map { items[$0].id })
        let next = CanvasAccessibility.nextSelection(in: items, after: selection, backward: backward)
        #expect(next == items[expected].id)
    }

    @Test("Nothing to select leaves Tab to the key view loop")
    func emptyCanvas() {
        #expect(CanvasAccessibility.nextSelection(in: [], after: [], backward: false) == nil)
    }

    @MainActor
    @Test("The canvas is a layout area with one element per annotation")
    func canvasTree() throws {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 200, height: 100), scale: 1)
        ))
        model.document.add(Self.arrow(Self.red))
        model.document.add(Self.arrow(Self.blue))
        let context = try #require(CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let canvas = try AnnotationCanvasView(model: model, baseImage: #require(context.makeImage()))

        #expect(canvas.isAccessibilityElement())
        #expect(canvas.accessibilityRole() == .layoutArea)
        let children = try #require(canvas.accessibilityChildren() as? [CanvasAnnotationElement])
        #expect(children.map { $0.accessibilityLabel() } == ["Arrow 1, red", "Arrow 2, blue"])

        #expect(children[1].accessibilityPerformPress())
        #expect(model.selection == [children[1].annotationID])
        #expect(children[1].isAccessibilitySelected())
        #expect(canvas.accessibilitySelectedChildren()?.count == 1)
    }
}
