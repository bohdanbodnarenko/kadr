import AnnotationModel
import CoreGraphics
import Foundation
import Testing

@Suite("Quadratic curve handle")
struct QuadraticCurveTests {
    @Test("Apex and control round-trip")
    func apexControlRoundTrip() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 0)
        let handle = CGPoint(x: 50, y: 40)
        let control = QuadraticCurve.control(start: start, end: end, apex: handle)
        let apex = QuadraticCurve.apex(start: start, end: end, control: control)
        #expect(abs(apex.x - handle.x) < 0.001)
        #expect(abs(apex.y - handle.y) < 0.001)
    }

    @Test("A straight chord's midpoint is the apex when the control sits on it")
    func straightApex() {
        let start = CGPoint(x: 0, y: 10)
        let end = CGPoint(x: 80, y: 10)
        let mid = CGPoint(x: 40, y: 10)
        let apex = QuadraticCurve.apex(start: start, end: end, control: mid)
        #expect(abs(apex.x - 40) < 0.001)
        #expect(abs(apex.y - 10) < 0.001)
    }
}

@Suite("Arrow dependents")
struct ArrowDependentsTests {
    @Test("layersNeedingUpdate includes arrows bound to the dragged shape")
    func includesDependents() {
        let target = AnnotationCommand.shape(ShapeSpec(rect: CGRect(x: 0, y: 0, width: 40, height: 40)))
        var arrow = ArrowSpec(start: CGPoint(x: 100, y: 20), end: CGPoint(x: 40, y: 20))
        arrow.endBinding = ArrowBinding(targetID: target.id, anchor: CGPoint(x: 1, y: 0.5))
        let commands = [target, .arrow(arrow)]
        let ids = ArrowDependents.layersNeedingUpdate(duringMoveOf: [target.id], in: commands)
        #expect(ids.contains(target.id))
        #expect(ids.contains(arrow.id))
    }
}

@Suite("Spotlight composite")
struct SpotlightCompositeTests {
    @Test("Two spotlights share one dim and both holes")
    func twoHolesOneDim() {
        let first = SpotlightSpec(rect: CGRect(x: 10, y: 10, width: 40, height: 40), dimOpacity: 0.4)
        let second = SpotlightSpec(rect: CGRect(x: 80, y: 10, width: 40, height: 40), dimOpacity: 0.7)
        let composite = SpotlightComposite.from(commands: [.spotlight(first), .spotlight(second)])
        #expect(composite?.holes.count == 2)
        #expect(composite?.dimOpacity == 0.7)
    }
}
