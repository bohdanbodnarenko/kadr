import CoreGraphics
import Foundation

/// Chaikin corner-cutting for freehand strokes (docs/16 ED-11).
///
/// Raw sampled points stay on the spec (`isSmoothed` is a render flag) so the original
/// input is never lost. Two iterations is enough to look like a pen rather than a
/// polyline without collapsing tight corners.
public enum PathSmoothing: Sendable {
    public static func smoothed(_ points: [CGPoint], iterations: Int = 2) -> [CGPoint] {
        guard points.count >= 3, iterations > 0 else { return points }
        var current = points
        for _ in 0 ..< iterations {
            current = chaikin(current)
        }
        return current
    }

    private static func chaikin(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var result: [CGPoint] = [points[0]]
        result.reserveCapacity(points.count * 2)
        for index in 0 ..< (points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            result.append(CGPoint(
                x: start.x * 0.75 + end.x * 0.25,
                y: start.y * 0.75 + end.y * 0.25
            ))
            result.append(CGPoint(
                x: start.x * 0.25 + end.x * 0.75,
                y: start.y * 0.25 + end.y * 0.75
            ))
        }
        result.append(points[points.count - 1])
        return result
    }
}
