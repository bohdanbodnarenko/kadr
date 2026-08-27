import CoreGraphics
import Foundation

/// Hit-testing against annotation *geometry*, not against rendered layers (docs/04 §6).
///
/// Testing the model rather than the layer tree is what lets a two-point arrow be
/// grabbed along its shaft, keeps hit areas stable while a drag is in flight, and means
/// selection behaviour can be tested without rendering anything.
public enum AnnotationHitTesting {
    /// How far from a thin annotation still counts as a hit, in points.
    ///
    /// A four-point arrow is nearly impossible to click on its exact pixels, so thin
    /// annotations get a forgiving margin on top of their stroke width.
    public static let minimumTouchTolerance: CGFloat = 6

    /// Whether a point hits one annotation.
    public static func hitTest(_ command: AnnotationCommand, at point: CGPoint) -> Bool {
        switch command {
        case let .arrow(spec):
            hitsPolyline(arrowPolyline(spec), at: point, tolerance: tolerance(for: spec.stroke))
        case let .line(spec):
            hitsSegment(from: spec.start, to: spec.end, at: point, tolerance: tolerance(for: spec.stroke))
        case let .shape(spec):
            hitsShape(spec, at: point)
        case let .freehand(spec):
            hitsPolyline(spec.points, at: point, tolerance: tolerance(for: spec.stroke))
        case let .highlighter(spec):
            hitsPolyline(spec.points, at: point, tolerance: tolerance(for: spec.stroke))
        case let .text(spec):
            spec.rect.contains(point)
        case let .redaction(spec):
            spec.rect.contains(point)
        case let .counter(spec):
            hypot(point.x - spec.center.x, point.y - spec.center.y) <= spec.radius
        case .crop:
            // The crop is edited through its own handles, not by clicking the canvas.
            false
        }
    }

    /// The frontmost annotation under a point, or `nil`.
    ///
    /// Front to back, because that is the one the user can see and therefore the one they
    /// meant to click.
    public static func topmost(in commands: [AnnotationCommand], at point: CGPoint) -> AnnotationCommand? {
        commands.reversed().first { $0.isSelectable && hitTest($0, at: point) }
    }

    /// Every annotation a marquee encloses (docs/03 §3).
    ///
    /// Enclosure, not intersection: a marquee that grabs everything it merely brushes
    /// past is maddening to use.
    public static func enclosed(in commands: [AnnotationCommand], by rect: CGRect) -> [AnnotationCommand] {
        let marquee = rect.standardized
        return commands.filter { $0.isSelectable && marquee.contains(boundingBox(of: $0)) }
    }

    /// The bounding box of an annotation, including its stroke.
    public static func boundingBox(of command: AnnotationCommand) -> CGRect {
        switch command {
        case let .arrow(spec):
            polylineBounds(arrowPolyline(spec)).insetBy(dx: -spec.stroke.width, dy: -spec.stroke.width)
        case let .line(spec):
            polylineBounds([spec.start, spec.end])
                .insetBy(dx: -spec.stroke.width, dy: -spec.stroke.width)
        case let .shape(spec):
            spec.rect.standardized.insetBy(dx: -spec.stroke.width / 2, dy: -spec.stroke.width / 2)
        case let .freehand(spec):
            polylineBounds(spec.points).insetBy(dx: -spec.stroke.width, dy: -spec.stroke.width)
        case let .highlighter(spec):
            polylineBounds(spec.points).insetBy(dx: -spec.stroke.width / 2, dy: -spec.stroke.width / 2)
        case let .text(spec):
            spec.rect.standardized
        case let .redaction(spec):
            spec.rect.standardized
        case let .counter(spec):
            CGRect(
                x: spec.center.x - spec.radius,
                y: spec.center.y - spec.radius,
                width: spec.radius * 2,
                height: spec.radius * 2
            )
        case let .crop(spec):
            spec.rect.standardized
        }
    }

    // MARK: - Geometry

    private static func tolerance(for stroke: StrokeStyle) -> CGFloat {
        max(stroke.width / 2, minimumTouchTolerance)
    }

    /// A curved arrow approximated as a polyline, which is enough for hit-testing and
    /// avoids solving the Bézier.
    static func arrowPolyline(_ spec: ArrowSpec, segments: Int = 16) -> [CGPoint] {
        guard let control = spec.controlPoint else { return [spec.start, spec.end] }
        return (0 ... segments).map { step in
            // Quadratic Bézier at parameter `progress`.
            let progress = CGFloat(step) / CGFloat(segments)
            let inverse = 1 - progress
            return CGPoint(
                x: inverse * inverse * spec.start.x
                    + 2 * inverse * progress * control.x
                    + progress * progress * spec.end.x,
                y: inverse * inverse * spec.start.y
                    + 2 * inverse * progress * control.y
                    + progress * progress * spec.end.y
            )
        }
    }

    private static func hitsShape(_ spec: ShapeSpec, at point: CGPoint) -> Bool {
        let rect = spec.rect.standardized
        let outer = rect.insetBy(dx: -tolerance(for: spec.stroke), dy: -tolerance(for: spec.stroke))
        guard outer.contains(point) else { return false }

        // A filled shape is grabbable anywhere inside it; an unfilled one only on its edge,
        // so a big empty rectangle does not block everything underneath it.
        let isFilled = spec.fill.color != nil
        switch spec.kind {
        case .rectangle, .roundedRectangle:
            if isFilled {
                return true
            }
            let inner = rect.insetBy(dx: tolerance(for: spec.stroke), dy: tolerance(for: spec.stroke))
            return !inner.contains(point)
        case .ellipse:
            let normalised = normalisedEllipseDistance(point, in: rect)
            if isFilled {
                return normalised <= 1.05
            }
            let innerRect = rect.insetBy(dx: tolerance(for: spec.stroke) * 2, dy: tolerance(for: spec.stroke) * 2)
            let inner = normalisedEllipseDistance(point, in: innerRect)
            return normalised <= 1.05 && inner >= 1
        }
    }

    /// 1 on the ellipse, less inside, more outside.
    private static func normalisedEllipseDistance(_ point: CGPoint, in rect: CGRect) -> CGFloat {
        guard rect.width > 0, rect.height > 0 else { return .infinity }
        let dx = (point.x - rect.midX) / (rect.width / 2)
        let dy = (point.y - rect.midY) / (rect.height / 2)
        return dx * dx + dy * dy
    }

    private static func hitsPolyline(_ points: [CGPoint], at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard points.count > 1 else {
            guard let only = points.first else { return false }
            return hypot(point.x - only.x, point.y - only.y) <= tolerance
        }
        return points.dropLast().indices.contains { index in
            hitsSegment(from: points[index], to: points[index + 1], at: point, tolerance: tolerance)
        }
    }

    static func hitsSegment(from start: CGPoint, to end: CGPoint, at point: CGPoint, tolerance: CGFloat) -> Bool {
        distanceToSegment(point, from: start, to: end) <= tolerance
    }

    /// Shortest distance from a point to a line segment.
    static func distanceToSegment(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        // How far along the segment the nearest point lies, clamped to its ends.
        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let clamped = min(max(projection, 0), 1)
        let nearest = CGPoint(x: start.x + clamped * dx, y: start.y + clamped * dy)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    private static func polylineBounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
