import CoreGraphics
import Foundation

/// Quadratic Bézier helpers for a curved arrow's middle handle (docs/16 ED-8).
///
/// The handle sits on the curve at t = 0.5, not at the stored control point. Storing the
/// pointer as the control put the apex halfway between the chord and the pointer, so the
/// handle looked like it had missed the shaft.
public enum QuadraticCurve {
    /// B(0.5) = (start + 2·control + end) / 4.
    public static func apex(start: CGPoint, end: CGPoint, control: CGPoint) -> CGPoint {
        CGPoint(
            x: (start.x + 2 * control.x + end.x) / 4,
            y: (start.y + 2 * control.y + end.y) / 4
        )
    }

    /// The control that puts B(0.5) at `apex`: control = 2·apex − (start + end) / 2.
    public static func control(start: CGPoint, end: CGPoint, apex: CGPoint) -> CGPoint {
        CGPoint(
            x: 2 * apex.x - (start.x + end.x) / 2,
            y: 2 * apex.y - (start.y + end.y) / 2
        )
    }
}

/// Arrows that must move when another annotation is dragged (docs/16 ED-5).
public enum ArrowDependents {
    /// Target id → the arrows bound to it.
    public static func map(in commands: [AnnotationCommand]) -> [AnnotationID: [AnnotationID]] {
        var result: [AnnotationID: [AnnotationID]] = [:]
        for command in commands {
            guard case let .arrow(spec) = command else { continue }
            for binding in [spec.startBinding, spec.endBinding].compactMap(\.self) {
                result[binding.targetID, default: []].append(spec.id)
            }
        }
        return result
    }

    /// The dragged ids plus every arrow bound to them.
    public static func layersNeedingUpdate(
        duringMoveOf selected: Set<AnnotationID>,
        in commands: [AnnotationCommand]
    ) -> Set<AnnotationID> {
        let dependents = map(in: commands)
        var ids = selected
        for id in selected {
            ids.formUnion(dependents[id] ?? [])
        }
        return ids
    }
}
