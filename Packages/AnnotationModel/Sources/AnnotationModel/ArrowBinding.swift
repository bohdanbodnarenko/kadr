import CoreGraphics
import Foundation

/// An arrow endpoint attached to another annotation (docs/09 U1.7).
///
/// Written from the behaviour rather than from anyone's source: bindings are the single
/// most differentiating annotation feature, and the reference implementation is licence-
/// tainted, so this is a clean reimplementation in our own command model (docs/08 §1).
///
/// The anchor is normalized to the target's own box, which is what makes a binding survive
/// the target being *resized* as well as moved: an anchor of (0.5, 0) stays the top centre
/// however big the box gets. Storing a point offset instead would drift off the shape the
/// moment it changed size.
public struct ArrowBinding: Codable, Hashable, Sendable {
    /// The annotation this end is attached to.
    public var targetID: AnnotationID
    /// Where on the target, in its own 0…1 space with the origin at its top-left.
    public var anchor: CGPoint

    public init(targetID: AnnotationID, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.targetID = targetID
        // Clamped a little outside the box, so an anchor can sit just off an edge without
        // being snapped back — but not so far that a binding points into empty space.
        self.anchor = CGPoint(
            x: min(max(anchor.x, -0.5), 1.5),
            y: min(max(anchor.y, -0.5), 1.5)
        )
    }

    /// The anchor in the document's coordinates, given the target's current box.
    public func point(in box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + box.width * anchor.x, y: box.minY + box.height * anchor.y)
    }

    /// The anchor a point on (or near) `box` corresponds to.
    public static func anchor(for point: CGPoint, in box: CGRect) -> CGPoint {
        guard box.width > 0, box.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height)
    }

    private enum CodingKeys: String, CodingKey {
        case targetID, anchor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            targetID: container.decode(AnnotationID.self, forKey: .targetID),
            anchor: container.decodeIfPresent(CGPoint.self, forKey: .anchor)
                ?? CGPoint(x: 0.5, y: 0.5)
        )
    }
}

/// Where a bound arrow actually starts and ends (docs/09 U1.7).
///
/// Pure, and computed rather than stored, because a binding's whole point is that it is
/// *not* a position: storing the resolved endpoint would mean updating every bound arrow
/// on every drag of every shape, and missing one is how an arrow ends up pointing at
/// nothing. Resolving on the way to the screen means there is nothing to miss.
public enum ArrowBindingResolver {
    /// The arrow as it should be drawn, with bound ends moved onto their targets.
    ///
    /// An unbound arrow, or one whose target has gone, comes back unchanged — the stored
    /// endpoint is the last place the arrow was, which is where the user last saw it.
    public static func resolved(_ spec: ArrowSpec, in commands: [AnnotationCommand]) -> ArrowSpec {
        guard spec.startBinding != nil || spec.endBinding != nil else { return spec }
        var resolved = spec

        // Both ends are computed from the *stored* geometry, not from each other's
        // resolved values: resolving the end against an already-resolved start would make
        // the result depend on which end was done first.
        if let binding = spec.startBinding, let target = target(binding, in: commands) {
            resolved.start = endpoint(binding, target: target, aimingFrom: spec.end)
        }
        if let binding = spec.endBinding, let target = target(binding, in: commands) {
            resolved.end = endpoint(binding, target: target, aimingFrom: spec.start)
        }
        return resolved
    }

    private static func target(
        _ binding: ArrowBinding,
        in commands: [AnnotationCommand]
    ) -> AnnotationCommand? {
        commands.first { $0.id == binding.targetID }
    }

    /// One end, trimmed to the target's edge.
    ///
    /// The anchor is where the arrow *aims*; the endpoint is where it stops. Stopping at
    /// the anchor would bury the arrowhead inside the shape — the head belongs on the
    /// boundary, pointing in.
    static func endpoint(
        _ binding: ArrowBinding,
        target: AnnotationCommand,
        aimingFrom other: CGPoint
    ) -> CGPoint {
        let box = AnnotationHitTesting.boundingBox(of: target)
        let anchor = binding.point(in: box)
        guard box.width > 0, box.height > 0 else { return anchor }

        // An arrow whose other end is inside the target has no edge to stop at: any
        // crossing would be behind the head. Aim at the anchor and let it be.
        guard !box.insetBy(dx: -0.001, dy: -0.001).contains(other) else { return anchor }

        if case let .shape(shape) = target, shape.kind == .ellipse {
            return ellipseCrossing(from: other, to: anchor, in: box) ?? anchor
        }
        return rectCrossing(from: other, to: anchor, in: box) ?? anchor
    }

    /// Where the segment `other → anchor` last crosses the rect on its way in.
    ///
    /// Parameterised along the segment so the *first* crossing is taken: an arrow passing
    /// through a shape on its way to an anchor on the far side should stop at the near
    /// edge, which is where it visually meets the shape.
    static func rectCrossing(from other: CGPoint, to anchor: CGPoint, in box: CGRect) -> CGPoint? {
        let run = CGPoint(x: anchor.x - other.x, y: anchor.y - other.y)
        guard abs(run.x) > 1e-9 || abs(run.y) > 1e-9 else { return nil }

        var best: CGFloat?
        for candidate in crossings(other: other, run: run, box: box) {
            guard candidate >= 0, candidate <= 1 else { continue }
            best = min(best ?? candidate, candidate)
        }
        guard let best else { return nil }
        return CGPoint(x: other.x + run.x * best, y: other.y + run.y * best)
    }

    /// The parameters at which the segment meets each of the rect's four edges, keeping
    /// only the ones that land within the edge's own span.
    private static func crossings(other: CGPoint, run: CGPoint, box: CGRect) -> [CGFloat] {
        var found: [CGFloat] = []
        let tolerance: CGFloat = 1e-6

        if abs(run.x) > tolerance {
            for edgeX in [box.minX, box.maxX] {
                let parameter = (edgeX - other.x) / run.x
                let crossingY = other.y + run.y * parameter
                if crossingY >= box.minY - tolerance, crossingY <= box.maxY + tolerance {
                    found.append(parameter)
                }
            }
        }
        if abs(run.y) > tolerance {
            for edgeY in [box.minY, box.maxY] {
                let parameter = (edgeY - other.y) / run.y
                let crossingX = other.x + run.x * parameter
                if crossingX >= box.minX - tolerance, crossingX <= box.maxX + tolerance {
                    found.append(parameter)
                }
            }
        }
        return found
    }

    /// The same, for an ellipse inscribed in the box.
    ///
    /// Solved in the space where the ellipse is a unit circle, because a circle-segment
    /// intersection is a quadratic and an ellipse-segment intersection is an argument.
    static func ellipseCrossing(from other: CGPoint, to anchor: CGPoint, in box: CGRect) -> CGPoint? {
        let radiusX = box.width / 2
        let radiusY = box.height / 2
        guard radiusX > 0, radiusY > 0 else { return nil }
        let centre = CGPoint(x: box.midX, y: box.midY)

        // Into unit-circle space.
        let origin = CGPoint(x: (other.x - centre.x) / radiusX, y: (other.y - centre.y) / radiusY)
        let target = CGPoint(x: (anchor.x - centre.x) / radiusX, y: (anchor.y - centre.y) / radiusY)
        let run = CGPoint(x: target.x - origin.x, y: target.y - origin.y)

        // |origin + t·run|² = 1, as a quadratic in t.
        let quadratic = run.x * run.x + run.y * run.y
        let linear = 2 * (origin.x * run.x + origin.y * run.y)
        let constant = origin.x * origin.x + origin.y * origin.y - 1
        guard quadratic > 1e-12 else { return nil }

        let discriminant = linear * linear - 4 * quadratic * constant
        guard discriminant >= 0 else { return nil }
        let root = sqrt(discriminant)

        let candidates = [
            (-linear - root) / (2 * quadratic),
            (-linear + root) / (2 * quadratic)
        ].filter { $0 >= 0 && $0 <= 1 }
        guard let parameter = candidates.min() else { return nil }

        return CGPoint(
            x: other.x + (anchor.x - other.x) * parameter,
            y: other.y + (anchor.y - other.y) * parameter
        )
    }
}
