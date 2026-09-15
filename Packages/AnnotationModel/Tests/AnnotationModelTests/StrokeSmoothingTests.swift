import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

@Suite("Stroke smoothing")
struct StrokeSmoothingTests {
    @Test("RDP keeps endpoints and drops a collinear middle point")
    func rdpDropsCollinear() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 5, y: 0.1),
            CGPoint(x: 10, y: 0)
        ]
        let simplified = StrokeSmoothing.rdp(points, epsilon: 0.5)
        #expect(simplified.count == 2)
        #expect(simplified.first == points.first)
        #expect(simplified.last == points.last)
    }

    @Test("A corner farther than epsilon is kept")
    func rdpKeepsCorner() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 5, y: 8),
            CGPoint(x: 10, y: 0)
        ]
        let simplified = StrokeSmoothing.rdp(points, epsilon: 0.5)
        #expect(simplified.count == 3)
    }

    @Test("Smoothing a polyline densifies it")
    func smoothingDensifies() {
        let points = (0 ..< 6).map { CGPoint(x: CGFloat($0) * 10, y: $0.isMultiple(of: 2) ? 0 : 8) }
        let smoothed = StrokeSmoothing.smoothed(points)
        #expect(smoothed.count > points.count)
        #expect(smoothed.first == points.first)
    }

    @Test("Two points are returned unchanged")
    func shortStroke() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 3)]
        #expect(StrokeSmoothing.smoothed(points) == points)
    }
}
