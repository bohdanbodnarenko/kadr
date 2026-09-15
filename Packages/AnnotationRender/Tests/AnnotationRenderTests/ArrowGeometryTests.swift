import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

@Suite("Arrow geometry")
struct ArrowGeometryTests {
    @Test("Head length is clamped between 1.5w and 4w, with a floor", arguments: [
        (chord: CGFloat(20), width: CGFloat(4), expected: CGFloat(8)),
        (chord: CGFloat(100), width: CGFloat(4), expected: CGFloat(16)),
        (chord: CGFloat(400), width: CGFloat(4), expected: CGFloat(16))
    ])
    func headLengthTable(chord: CGFloat, width: CGFloat, expected: CGFloat) {
        #expect(abs(ArrowGeometry.headLength(chord: chord, width: width) - expected) < 0.01)
    }

    @Test("Canvas and export share the same shaft path")
    func shaftMatchesFactory() {
        let spec = ArrowSpec(
            start: .zero,
            end: CGPoint(x: 80, y: 0),
            head: .filled,
            startHead: .open,
            stroke: StrokeStyle(width: 6)
        )
        #expect(AnnotationLayerFactory.arrowPath(spec) == ArrowGeometry.make(spec).shaft)
    }
}

@Suite("Text rendering")
struct TextRenderingTests {
    @Test("Multi-line text grows its rect rather than clipping")
    func multiLineGrows() {
        let original = TextSpec(
            string: "One",
            rect: CGRect(x: 10, y: 10, width: 40, height: 20),
            style: TextStyle(fontSize: 18),
            autoWidth: true
        )
        let fitted = TextRendering.fitted(original)
        let wrapped = TextRendering.fitted(TextSpec(
            string: "One\nTwo\nThree",
            rect: fitted.rect,
            style: fitted.style,
            autoWidth: true
        ))
        #expect(wrapped.rect.height > fitted.rect.height)
    }

    @Test("A legacy file keeps a fixed wrap width")
    func legacyFixedWidth() throws {
        let encoded = try JSONEncoder().encode(TextSpec(
            string: "Hi",
            rect: CGRect(x: 0, y: 0, width: 200, height: 40)
        ))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "autoWidth")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let spec = try JSONDecoder().decode(TextSpec.self, from: stripped)
        #expect(spec.autoWidth == false)
    }
}
