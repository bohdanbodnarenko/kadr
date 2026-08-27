import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

@Suite("Hit-testing geometry")
struct HitTestingTests {
    struct HitCase: Sendable {
        let name: String
        let command: AnnotationCommand
        let point: CGPoint
        let hits: Bool
    }

    /// A horizontal arrow from (0,50) to (100,50) with a 4-point stroke.
    private static let arrow = AnnotationCommand.arrow(ArrowSpec(
        start: CGPoint(x: 0, y: 50),
        end: CGPoint(x: 100, y: 50)
    ))
    /// An unfilled rectangle: grabbable on its edge only.
    private static let hollowRect = AnnotationCommand.shape(ShapeSpec(
        rect: CGRect(x: 0, y: 0, width: 100, height: 100)
    ))
    private static let filledRect = AnnotationCommand.shape(ShapeSpec(
        rect: CGRect(x: 0, y: 0, width: 100, height: 100),
        fill: FillStyle(color: .white)
    ))
    private static let ellipse = AnnotationCommand.shape(ShapeSpec(
        kind: .ellipse,
        rect: CGRect(x: 0, y: 0, width: 100, height: 50),
        fill: FillStyle(color: .white)
    ))
    private static let badge = AnnotationCommand.counter(CounterSpec(
        center: CGPoint(x: 50, y: 50),
        radius: 20
    ))
    private static let label = AnnotationCommand.text(TextSpec(
        string: "Hi",
        rect: CGRect(x: 10, y: 10, width: 100, height: 30)
    ))

    static let cases: [HitCase] = [
        HitCase(name: "on the arrow's shaft", command: arrow, point: CGPoint(x: 50, y: 50), hits: true),
        HitCase(name: "just beside the shaft", command: arrow, point: CGPoint(x: 50, y: 54), hits: true),
        HitCase(name: "well away from the shaft", command: arrow, point: CGPoint(x: 50, y: 90), hits: false),
        HitCase(name: "past the arrow's end", command: arrow, point: CGPoint(x: 130, y: 50), hits: false),

        HitCase(name: "on a hollow rect's edge", command: hollowRect, point: CGPoint(x: 0, y: 50), hits: true),
        HitCase(name: "inside a hollow rect", command: hollowRect, point: CGPoint(x: 50, y: 50), hits: false),
        HitCase(name: "inside a filled rect", command: filledRect, point: CGPoint(x: 50, y: 50), hits: true),
        HitCase(name: "outside a filled rect", command: filledRect, point: CGPoint(x: 200, y: 50), hits: false),

        HitCase(name: "inside a filled ellipse", command: ellipse, point: CGPoint(x: 50, y: 25), hits: true),
        HitCase(
            name: "in the ellipse's corner, outside the curve",
            command: ellipse,
            point: CGPoint(x: 3, y: 3),
            hits: false
        ),

        HitCase(name: "on a counter badge", command: badge, point: CGPoint(x: 55, y: 55), hits: true),
        HitCase(name: "outside a counter badge", command: badge, point: CGPoint(x: 80, y: 80), hits: false),

        HitCase(name: "inside a text frame", command: label, point: CGPoint(x: 20, y: 20), hits: true),
        HitCase(name: "outside a text frame", command: label, point: CGPoint(x: 200, y: 20), hits: false)
    ]

    @Test("Points hit the annotations they look like they hit", arguments: cases)
    func hitTable(testCase: HitCase) {
        #expect(
            AnnotationHitTesting.hitTest(testCase.command, at: testCase.point) == testCase.hits,
            "\(testCase.name)"
        )
    }

    @Test("A thin stroke still gets a forgiving hit area")
    func thinStrokesAreGrabbable() {
        let hairline = AnnotationCommand.line(LineSpec(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 100, y: 0),
            stroke: StrokeStyle(width: 1)
        ))
        // Five points off a one-point line: impossible to click exactly, must still hit.
        #expect(AnnotationHitTesting.hitTest(hairline, at: CGPoint(x: 50, y: 5)))
        #expect(AnnotationHitTesting.hitTest(hairline, at: CGPoint(x: 50, y: 20)) == false)
    }

    @Test("A curved arrow is hit along its curve, not its chord")
    func curvedArrowFollowsTheCurve() {
        let curved = AnnotationCommand.arrow(ArrowSpec(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 100, y: 0),
            controlPoint: CGPoint(x: 50, y: 100)
        ))
        // The curve's apex is halfway to the control point.
        #expect(AnnotationHitTesting.hitTest(curved, at: CGPoint(x: 50, y: 50)))
        // The straight chord between the ends is not the arrow.
        #expect(AnnotationHitTesting.hitTest(curved, at: CGPoint(x: 50, y: 0)) == false)
    }

    @Test("A freehand stroke is hit anywhere along it")
    func freehandFollowsItsPoints() {
        let scribble = AnnotationCommand.freehand(FreehandSpec(points: [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 100, y: 0)
        ]))
        #expect(AnnotationHitTesting.hitTest(scribble, at: CGPoint(x: 25, y: 25)))
        #expect(AnnotationHitTesting.hitTest(scribble, at: CGPoint(x: 50, y: 0)) == false)
    }

    @Test("A single-point stroke is still hittable")
    func singlePointStroke() {
        let dot = AnnotationCommand.freehand(FreehandSpec(points: [CGPoint(x: 10, y: 10)]))
        #expect(AnnotationHitTesting.hitTest(dot, at: CGPoint(x: 11, y: 11)))
        #expect(AnnotationHitTesting.hitTest(dot, at: CGPoint(x: 40, y: 40)) == false)
    }

    @Test("An empty stroke hits nothing rather than crashing")
    func emptyStroke() {
        let empty = AnnotationCommand.freehand(FreehandSpec(points: []))
        #expect(AnnotationHitTesting.hitTest(empty, at: .zero) == false)
    }

    @Test("The frontmost annotation under the point wins")
    func topmostWins() {
        let back = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            fill: FillStyle(color: .white)
        ))
        let front = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(x: 20, y: 20, width: 60, height: 60),
            fill: FillStyle(color: .black)
        ))
        let hit = AnnotationHitTesting.topmost(in: [back, front], at: CGPoint(x: 50, y: 50))
        #expect(hit?.id == front.id)
    }

    @Test("A crop never intercepts a click meant for something under it")
    func cropIsNotSelectable() {
        let crop = AnnotationCommand.crop(CropSpec(rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let shape = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            fill: FillStyle(color: .white)
        ))
        let hit = AnnotationHitTesting.topmost(in: [shape, crop], at: CGPoint(x: 50, y: 50))
        #expect(hit?.id == shape.id)
    }

    @Test("Nothing under the point means nothing selected")
    func emptySpace() {
        #expect(AnnotationHitTesting.topmost(in: [Self.badge], at: CGPoint(x: 500, y: 500)) == nil)
    }

    @Test("A marquee takes what it encloses, not what it brushes")
    func marqueeEnclosesRatherThanIntersects() {
        let inside = AnnotationCommand.shape(ShapeSpec(rect: CGRect(x: 20, y: 20, width: 20, height: 20)))
        let straddling = AnnotationCommand.shape(ShapeSpec(rect: CGRect(x: 90, y: 20, width: 40, height: 20)))

        let selected = AnnotationHitTesting.enclosed(
            in: [inside, straddling],
            by: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(selected.map(\.id) == [inside.id])
    }

    @Test("A marquee drawn backwards still works")
    func backwardsMarquee() {
        let target = AnnotationCommand.shape(ShapeSpec(rect: CGRect(x: 20, y: 20, width: 20, height: 20)))
        let selected = AnnotationHitTesting.enclosed(
            in: [target],
            by: CGRect(x: 100, y: 100, width: -100, height: -100)
        )
        #expect(selected.count == 1)
    }

    @Test("Bounding boxes include the stroke, so handles do not clip it")
    func boundsIncludeStroke() {
        let thick = AnnotationCommand.shape(ShapeSpec(
            rect: CGRect(x: 10, y: 10, width: 100, height: 100),
            stroke: StrokeStyle(width: 20)
        ))
        let bounds = AnnotationHitTesting.boundingBox(of: thick)
        #expect(bounds.minX < 10)
        #expect(bounds.maxX > 110)
    }

    @Test("Distance to a zero-length segment is the distance to the point")
    func degenerateSegment() {
        let distance = AnnotationHitTesting.distanceToSegment(
            CGPoint(x: 3, y: 4),
            from: .zero,
            to: .zero
        )
        #expect(distance == 5)
    }
}
