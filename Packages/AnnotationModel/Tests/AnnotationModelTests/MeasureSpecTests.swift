import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

/// What a measurement says (docs/03 §3 P3, docs/06 M21).
///
/// The readout is the entire feature: a ruler that reports 640 where the file has 1280 is
/// worse than no ruler, because the number looks authoritative.
@Suite("Measurements")
struct MeasureSpecTests {
    @Test("On a 1× capture the number is plain pixels")
    func nonRetinaDistance() {
        let spec = MeasureSpec(start: .zero, end: CGPoint(x: 100, y: 0))
        #expect(spec.readout(scale: 1) == "100 px")
    }

    @Test("On a Retina capture both numbers are shown, and the pixel one is the file's")
    func retinaDistance() {
        let spec = MeasureSpec(start: .zero, end: CGPoint(x: 100, y: 0))
        #expect(spec.readout(scale: 2) == "100 pt · 200 px")
    }

    @Test("A box reports width and height")
    func boxReadout() {
        let spec = MeasureSpec(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 90, y: 80),
            measuresBox: true
        )
        #expect(spec.readout(scale: 1) == "80 × 60 px")
        #expect(spec.readout(scale: 2) == "80 × 60 pt · 160 × 120 px")
    }

    @Test("Dragging backwards measures the same distance")
    func directionDoesNotMatter() {
        let forwards = MeasureSpec(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 10))
        let backwards = MeasureSpec(start: CGPoint(x: 60, y: 10), end: CGPoint(x: 10, y: 10))
        #expect(forwards.readout(scale: 2) == backwards.readout(scale: 2))
        #expect(forwards.rect == backwards.rect)
    }

    @Test("A diagonal measures the hypotenuse, not a side")
    func diagonal() {
        let spec = MeasureSpec(start: .zero, end: CGPoint(x: 3, y: 4))
        #expect(spec.length == 5)
        #expect(spec.readout(scale: 1) == "5 px")
    }

    @Test("Axis alignment is about how the drag reads, not exact equality", arguments: [
        (CGPoint(x: 100, y: 0), true),
        (CGPoint(x: 100, y: 1), true),
        (CGPoint(x: 100, y: 40), false),
        (CGPoint(x: 0, y: 100), true)
    ])
    func axisAlignment(end: CGPoint, expected: Bool) {
        #expect(MeasureSpec(start: .zero, end: end).isAxisAligned == expected)
    }

    @Test("A measurement survives a round trip through the document format")
    func codableRoundTrip() throws {
        let spec = MeasureSpec(
            start: CGPoint(x: 4, y: 8),
            end: CGPoint(x: 44, y: 8),
            measuresBox: true
        )
        let command = AnnotationCommand.measure(spec)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(AnnotationCommand.self, from: data)
        #expect(decoded == command)
        #expect(decoded.tool == .measure)
    }

    @Test("A measurement is a selectable object, not canvas chrome")
    func isSelectable() {
        let command = AnnotationCommand.measure(MeasureSpec(start: .zero, end: CGPoint(x: 10, y: 0)))
        #expect(command.isSelectable)
        #expect(!AnnotationTool.measure.isCanvasChrome)
        #expect(AnnotationTool.measure.isPointerTool)
    }

    @Test("A distance measurement is grabbed by its line")
    func hitTestingDistance() {
        let spec = MeasureSpec(start: CGPoint(x: 0, y: 50), end: CGPoint(x: 100, y: 50))
        let command = AnnotationCommand.measure(spec)
        #expect(AnnotationHitTesting.hitTest(command, at: CGPoint(x: 50, y: 52)))
        #expect(!AnnotationHitTesting.hitTest(command, at: CGPoint(x: 50, y: 90)))
    }

    @Test("A box measurement is grabbed by its outline, so its contents stay clickable")
    func hitTestingBox() {
        let spec = MeasureSpec(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 200, y: 200),
            measuresBox: true
        )
        let command = AnnotationCommand.measure(spec)
        #expect(AnnotationHitTesting.hitTest(command, at: CGPoint(x: 100, y: 2)))
        #expect(!AnnotationHitTesting.hitTest(command, at: CGPoint(x: 100, y: 100)))
    }
}
