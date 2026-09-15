import CoreGraphics
import Foundation
import Testing
@testable import AnnotationModel

@Suite("Freehand smoothing")
struct PathSmoothingTests {
    @Test("Fewer than three points is a no-op")
    func shortPath() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        #expect(PathSmoothing.smoothed(points) == points)
    }

    @Test("Smoothing keeps the endpoints")
    func keepsEndpoints() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 20),
            CGPoint(x: 30, y: 0)
        ]
        let smoothed = PathSmoothing.smoothed(points)
        #expect(smoothed.first == points.first)
        #expect(smoothed.last == points.last)
        #expect(smoothed.count > points.count)
    }
}
