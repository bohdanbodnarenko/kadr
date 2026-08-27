import AnnotationModel
import CoreGraphics
import QuartzCore
import Testing
@testable import AnnotationRender

@Suite("Editing layer tree")
struct AnnotationLayerFactoryTests {
    @Test("Every drawable annotation gets a layer", arguments: [
        AnnotationCommand.arrow(ArrowSpec(start: .zero, end: CGPoint(x: 50, y: 50))),
        .shape(ShapeSpec(rect: CGRect(x: 0, y: 0, width: 20, height: 20))),
        .line(LineSpec(start: .zero, end: CGPoint(x: 10, y: 10))),
        .freehand(FreehandSpec(points: [.zero, CGPoint(x: 5, y: 5)])),
        .highlighter(HighlighterSpec(points: [.zero, CGPoint(x: 5, y: 5)])),
        .text(TextSpec(string: "x", rect: CGRect(x: 0, y: 0, width: 20, height: 20))),
        .counter(CounterSpec(center: CGPoint(x: 10, y: 10))),
        .redaction(RedactionSpec(rect: CGRect(x: 0, y: 0, width: 20, height: 20)))
    ])
    func makesLayers(command: AnnotationCommand) throws {
        let layer = try #require(AnnotationLayerFactory.makeLayer(for: command, contentsScale: 2))
        #expect(layer.contentsScale == 2)
        #expect(layer.name == command.id.rawValue.uuidString, "layers must be traceable to their annotation")
    }

    @Test("A crop is chrome, not an object on the canvas")
    func cropHasNoLayer() {
        let crop = AnnotationCommand.crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(AnnotationLayerFactory.makeLayer(for: crop, contentsScale: 2) == nil)
    }

    @Test("Dragging updates the existing layer instead of rebuilding it")
    func updateMutatesInPlace() throws {
        var spec = ShapeSpec(rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        let layer = try #require(
            AnnotationLayerFactory.makeLayer(for: .shape(spec), contentsScale: 2) as? CAShapeLayer
        )
        let before = layer.path

        spec.rect = CGRect(x: 50, y: 50, width: 80, height: 80)
        AnnotationLayerFactory.update(layer, for: .shape(spec))

        #expect(layer.path != before)
        #expect(layer.path?.boundingBox == CGRect(x: 50, y: 50, width: 80, height: 80))
    }

    @Test("A highlighter multiplies, so text under it stays readable")
    func highlighterMultiplies() throws {
        let command = AnnotationCommand.highlighter(HighlighterSpec(points: [.zero, CGPoint(x: 50, y: 0)]))
        let layer = try #require(AnnotationLayerFactory.makeLayer(for: command, contentsScale: 2))
        #expect(layer.compositingFilter as? String == "multiplyBlendMode")
    }

    @Test("An open arrow head is not filled in")
    func openArrowIsUnfilled() throws {
        let open = AnnotationCommand.arrow(ArrowSpec(start: .zero, end: CGPoint(x: 50, y: 0), head: .open))
        let filled = AnnotationCommand.arrow(ArrowSpec(start: .zero, end: CGPoint(x: 50, y: 0), head: .filled))

        let openLayer = try #require(
            AnnotationLayerFactory.makeLayer(for: open, contentsScale: 2) as? CAShapeLayer
        )
        let filledLayer = try #require(
            AnnotationLayerFactory.makeLayer(for: filled, contentsScale: 2) as? CAShapeLayer
        )

        #expect(openLayer.fillColor == nil)
        #expect(filledLayer.fillColor != nil)
    }

    @Test("A curved arrow's path is not the straight one")
    func curvedArrowDiffers() {
        let straight = ArrowSpec(start: .zero, end: CGPoint(x: 100, y: 0))
        let curved = ArrowSpec(start: .zero, end: CGPoint(x: 100, y: 0), controlPoint: CGPoint(x: 50, y: 80))

        #expect(AnnotationLayerFactory.arrowPath(straight) != AnnotationLayerFactory.arrowPath(curved))
        #expect(AnnotationLayerFactory.arrowPath(curved).boundingBox.height > 10)
    }

    @Test("A rounded rectangle's corner radius cannot exceed half its shorter side")
    func cornerRadiusIsClamped() {
        let spec = ShapeSpec(
            kind: .roundedRectangle(cornerRadius: 500),
            rect: CGRect(x: 0, y: 0, width: 40, height: 20)
        )
        // A radius larger than the rect would produce an inverted path; clamped it is a
        // capsule, which is what the user sees when they drag the slider to the end.
        #expect(AnnotationLayerFactory.shapePath(spec).boundingBox == CGRect(x: 0, y: 0, width: 40, height: 20))
    }

    @Test("An empty freehand stroke makes an empty path rather than crashing")
    func emptyStroke() {
        #expect(AnnotationLayerFactory.strokePath([]).isEmpty)
    }
}
