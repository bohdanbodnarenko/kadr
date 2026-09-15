import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

@Suite("Annotation rotation")
struct AnnotationRotationTests {
    @Test("Zero rotation leaves the point and the box alone")
    func identity() {
        let point = CGPoint(x: 12, y: 8)
        let rect = CGRect(x: 10, y: 10, width: 40, height: 20)
        #expect(AnnotationRotation.inverse(point, around: .zero, radians: 0) == point)
        #expect(AnnotationRotation.aabb(rect, radians: 0) == rect)
    }

    @Test("Inverse rotation round-trips a point around the centre")
    func inverseRoundTrip() {
        let center = CGPoint(x: 50, y: 40)
        let point = CGPoint(x: 80, y: 40)
        let rotated = AnnotationRotation.inverse(point, around: center, radians: -.pi / 2)
        let back = AnnotationRotation.inverse(rotated, around: center, radians: .pi / 2)
        #expect(abs(back.x - point.x) < 0.001)
        #expect(abs(back.y - point.y) < 0.001)
    }

    @Test("A 90° box AABB is the swapped size, centred")
    func rotatedAABB() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 10)
        let box = AnnotationRotation.aabb(rect, radians: .pi / 2)
        #expect(abs(box.width - 10) < 0.01)
        #expect(abs(box.height - 40) < 0.01)
        #expect(abs(box.midX - 20) < 0.01)
        #expect(abs(box.midY - 5) < 0.01)
    }

    @Test("⇧ snaps to 15°")
    func snap() {
        let twelve = 12 * CGFloat.pi / 180
        let snapped = AnnotationRotation.snap(twelve)
        #expect(abs(snapped * 180 / CGFloat.pi - 15) < 0.001)
    }
}
