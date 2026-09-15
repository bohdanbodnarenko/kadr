import CoreGraphics
import Foundation

public extension AnnotationCommand {
    var rotation: CGFloat {
        switch self {
        case let .shape(spec): spec.rotation
        case let .freehand(spec): spec.rotation
        case let .text(spec): spec.rotation
        case let .redaction(spec): spec.rotation
        case let .spotlight(spec): spec.rotation
        case let .image(spec): spec.rotation
        default: 0
        }
    }

    var canRotate: Bool {
        switch self {
        case .shape, .freehand, .text, .redaction, .spotlight, .image: true
        default: false
        }
    }

    func applying(rotation: CGFloat) -> AnnotationCommand {
        switch self {
        case var .shape(spec):
            spec.rotation = rotation
            return .shape(spec)
        case var .freehand(spec):
            spec.rotation = rotation
            return .freehand(spec)
        case var .text(spec):
            spec.rotation = rotation
            return .text(spec)
        case var .redaction(spec):
            spec.rotation = rotation
            return .redaction(spec)
        case var .spotlight(spec):
            spec.rotation = rotation
            return .spotlight(spec)
        case var .image(spec):
            spec.rotation = rotation
            return .image(spec)
        default:
            return self
        }
    }
}

/// Rotation stored on annotations, in radians (docs/16 ED-10).
///
/// Zero is identity so files written before this field existed stay compatible. ⇧ snaps
/// to 15° while dragging a rotate handle.
public enum AnnotationRotation: Sendable {
    public static let snapStepDegrees: CGFloat = 15

    public static func snap(_ radians: CGFloat) -> CGFloat {
        let degrees = radians * 180 / .pi
        let snapped = (degrees / snapStepDegrees).rounded() * snapStepDegrees
        return snapped * .pi / 180
    }

    public static func inverse(_ point: CGPoint, around center: CGPoint, radians: CGFloat) -> CGPoint {
        guard radians != 0 else { return point }
        let cosine = cos(-radians)
        let sine = sin(-radians)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + dx * cosine - dy * sine,
            y: center.y + dx * sine + dy * cosine
        )
    }

    public static func aabb(_ rect: CGRect, radians: CGFloat) -> CGRect {
        guard radians != 0 else { return rect.standardized }
        let box = rect.standardized
        let center = CGPoint(x: box.midX, y: box.midY)
        let cosine = cos(radians)
        let sine = sin(radians)
        let corners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: box.maxX, y: box.maxY)
        ]
        let mapped = corners.map { point in
            let dx = point.x - center.x
            let dy = point.y - center.y
            return CGPoint(
                x: center.x + dx * cosine - dy * sine,
                y: center.y + dx * sine + dy * cosine
            )
        }
        let xs = mapped.map(\.x)
        let ys = mapped.map(\.y)
        return CGRect(
            x: xs.min() ?? box.minX,
            y: ys.min() ?? box.minY,
            width: (xs.max() ?? box.maxX) - (xs.min() ?? box.minX),
            height: (ys.max() ?? box.maxY) - (ys.min() ?? box.minY)
        )
    }
}
