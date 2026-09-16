import AnnotationModel
import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import AnnotationRender

/// The text, counter and watermark layers redraw only when their pixels would change
/// (docs/10 R1).
///
/// Each of these re-ran CoreText on every update, and the canvas updates every layer on
/// every document change — so dragging one arrow re-rasterised every label on the canvas,
/// and the canvas-sized watermark with them. The guard is the redraw count, not a clock.
@Suite("Layer redraws")
@MainActor
struct LayerRedrawTests {
    /// What each step does to a text layer, and whether it should cost a redraw.
    enum TextStep: String, CaseIterable, Sendable {
        case same
        case moved
        case restyled
        case retyped
        case resized
        case denser
    }

    @Test("A text layer redraws only when its appearance changes", arguments: [
        (TextStep.same, false),
        (.moved, false),
        (.restyled, true),
        (.retyped, true),
        (.resized, true),
        (.denser, true)
    ])
    func textRedraws(step: TextStep, redraws: Bool) {
        let layer = TextBadgeLayer()
        layer.contentsScale = 2
        var spec = TextSpec(string: "Hello", rect: CGRect(x: 10, y: 10, width: 120, height: 30))
        layer.apply(spec)
        let before = layer.displayCount
        #expect(before == 1)

        switch step {
        case .same:
            break
        case .moved:
            spec.rect.origin = CGPoint(x: 300, y: 200)
        case .restyled:
            spec.style.fontSize += 4
        case .retyped:
            spec.string = "Hello, world"
        case .resized:
            spec.rect.size.width = 200
        case .denser:
            layer.contentsScale = 4
        }
        layer.apply(spec)
        #expect((layer.displayCount > before) == redraws)
        #expect(layer.frame.origin == TextRendering.frame(spec).origin)
    }

    @Test("A counter follows a drag without redrawing its digits, and redraws for a new number")
    func counterRedraws() {
        let layer = CounterBadgeLayer()
        layer.contentsScale = 2
        var spec = CounterSpec(number: 1, center: CGPoint(x: 40, y: 40), radius: 16)
        layer.apply(spec)
        #expect(layer.displayCount == 1)

        for offset in 1 ... 20 {
            spec.center = CGPoint(x: 40 + CGFloat(offset), y: 40)
            layer.apply(spec)
        }
        #expect(layer.displayCount == 1)
        #expect(layer.frame == CounterRendering.frame(spec))

        spec.number = 2
        layer.apply(spec)
        #expect(layer.displayCount == 2)

        spec.radius = 24
        layer.apply(spec)
        #expect(layer.displayCount == 3)
    }

    @Test("A watermark redraws only for a new spec, size or density, and holds no bitmap when off")
    func watermarkRedraws() {
        let layer = WatermarkLayer()
        layer.contentsScale = 2
        layer.frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        layer.apply(nil)
        #expect(layer.displayCount == 0)
        #expect(layer.contents == nil)
        #expect(layer.isHidden)

        let spec = WatermarkSpec(text: "Kadr")
        layer.apply(spec)
        #expect(layer.displayCount == 1)
        #expect(!layer.isHidden)

        layer.apply(spec)
        layer.apply(spec)
        #expect(layer.displayCount == 1, "an unchanged watermark must not redraw")

        var changed = spec
        changed.opacity = 0.8
        layer.apply(changed)
        #expect(layer.displayCount == 2)

        layer.apply(WatermarkSpec(text: "   "))
        #expect(layer.contents == nil, "an identity watermark releases its bitmap")
        #expect(layer.isHidden)

        layer.apply(changed)
        #expect(layer.displayCount == 3, "coming back needs a real draw")

        layer.contentsScale = 1
        layer.apply(changed)
        #expect(layer.displayCount == 4)
    }
}
