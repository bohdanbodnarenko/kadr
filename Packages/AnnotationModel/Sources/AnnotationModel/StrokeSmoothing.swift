import CoreGraphics
import Foundation

/// Ramer–Douglas–Peucker simplification plus centripetal Catmull–Rom sampling
/// (docs/16 ED-11).
///
/// Raw sampled points stay on the spec. This is a render-time path so smoothing can
/// improve without rewriting documents.
public enum StrokeSmoothing: Sendable {
    public static func smoothed(_ points: [CGPoint], epsilon: CGFloat = 0.5) -> [CGPoint] {
        let simplified = rdp(points, epsilon: epsilon)
        return catmullRom(simplified)
    }

    static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            var farthest = start
            var distance: CGFloat = 0
            for index in (start + 1) ..< end {
                let candidate = perpendicularDistance(points[index], from: points[start], to: points[end])
                if candidate > distance {
                    farthest = index
                    distance = candidate
                }
            }
            if distance > epsilon {
                keep[farthest] = true
                stack.append((start, farthest))
                stack.append((farthest, end))
            }
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private static func perpendicularDistance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        return abs((point.x - start.x) * dy - (point.y - start.y) * dx) / length
    }

    /// Samples a centripetal Catmull–Rom spline as a polyline the renderers already draw.
    private static func catmullRom(_ points: [CGPoint], samplesPerSpan: Int = 8) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        var result: [CGPoint] = [points[0]]
        let padded = [points[0]] + points + [points[points.count - 1]]
        for index in 1 ..< (padded.count - 2) {
            let p0 = padded[index - 1]
            let p1 = padded[index]
            let p2 = padded[index + 1]
            let p3 = padded[index + 2]
            for sample in 1 ... samplesPerSpan {
                let fraction = CGFloat(sample) / CGFloat(samplesPerSpan)
                result.append(centripetal(p0: p0, p1: p1, p2: p2, p3: p3, sample: fraction))
            }
        }
        return result
    }

    private static func centripetal(
        p0: CGPoint,
        p1: CGPoint,
        p2: CGPoint,
        p3: CGPoint,
        sample: CGFloat
    ) -> CGPoint {
        let t0: CGFloat = 0
        let t1 = t0 + knot(from: p0, to: p1)
        let t2 = t1 + knot(from: p1, to: p2)
        let t3 = t2 + knot(from: p2, to: p3)
        let time = t1 + (t2 - t1) * sample
        let a1 = mix(p0, p1, t0, t1, time)
        let a2 = mix(p1, p2, t1, t2, time)
        let a3 = mix(p2, p3, t2, t3, time)
        let b1 = mix(a1, a2, t0, t2, time)
        let b2 = mix(a2, a3, t1, t3, time)
        return mix(b1, b2, t1, t2, time)
    }

    private static func knot(from start: CGPoint, to end: CGPoint) -> CGFloat {
        max(pow(hypot(end.x - start.x, end.y - start.y), 0.5), 0.001)
    }

    private static func mix(
        _ start: CGPoint,
        _ end: CGPoint,
        _ t0: CGFloat,
        _ t1: CGFloat,
        _ time: CGFloat
    ) -> CGPoint {
        let span = t1 - t0
        guard span > 0 else { return end }
        let fromEnd = (t1 - time) / span
        let fromStart = (time - t0) / span
        return CGPoint(
            x: start.x * fromEnd + end.x * fromStart,
            y: start.y * fromEnd + end.y * fromStart
        )
    }
}
