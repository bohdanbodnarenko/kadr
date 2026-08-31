import CoreGraphics
import Foundation

public extension AnnotationCommand {
    /// Recolours the parts of this annotation the user thinks of as "the colour".
    ///
    /// Highlighter strokes keep their translucency so a green highlighter does not become
    /// an opaque green marker. A filled shape tints the fill to match, because a red
    /// outline around a leftover blue fill looks like two tools.
    func applying(color: AnnotationColor) -> AnnotationCommand {
        switch self {
        case var .arrow(spec):
            spec.stroke.color = color
            return .arrow(spec)
        case var .shape(spec):
            spec.stroke.color = color
            if let fill = spec.fill.color {
                spec.fill.color = color.withAlpha(fill.alpha)
            }
            return .shape(spec)
        case var .line(spec):
            spec.stroke.color = color
            return .line(spec)
        case var .freehand(spec):
            spec.stroke.color = color
            return .freehand(spec)
        case var .highlighter(spec):
            spec.stroke.color = color.withAlpha(spec.stroke.color.alpha)
            return .highlighter(spec)
        case var .text(spec):
            spec.style.color = color
            return .text(spec)
        case var .measure(spec):
            spec.stroke.color = color
            return .measure(spec)
        case var .counter(spec):
            spec.fill = color
            return .counter(spec)
        default:
            return self
        }
    }

    func applying(strokeWidth: CGFloat) -> AnnotationCommand {
        switch self {
        case var .arrow(spec):
            spec.stroke.width = strokeWidth
            return .arrow(spec)
        case var .shape(spec):
            spec.stroke.width = strokeWidth
            return .shape(spec)
        case var .line(spec):
            spec.stroke.width = strokeWidth
            return .line(spec)
        case var .freehand(spec):
            spec.stroke.width = strokeWidth
            return .freehand(spec)
        case var .highlighter(spec):
            spec.stroke.width = strokeWidth
            return .highlighter(spec)
        case var .measure(spec):
            spec.stroke.width = strokeWidth
            return .measure(spec)
        default:
            return self
        }
    }

    func applying(fillOpacity: Double) -> AnnotationCommand {
        guard case var .shape(spec) = self, let fill = spec.fill.color else { return self }
        spec.fill.color = fill.withAlpha(fillOpacity)
        return .shape(spec)
    }

    func applying(shapeKind: ShapeKind) -> AnnotationCommand {
        guard case var .shape(spec) = self else { return self }
        spec.kind = shapeKind
        return .shape(spec)
    }

    func applying(arrowHead: ArrowHead) -> AnnotationCommand {
        guard case var .arrow(spec) = self else { return self }
        spec.head = arrowHead
        return .arrow(spec)
    }

    func applying(redactionStyle: RedactionStyle) -> AnnotationCommand {
        guard case var .redaction(spec) = self else { return self }
        spec.style = redactionStyle
        return .redaction(spec)
    }

    /// A copy that is a new annotation, not a second handle on this one.
    ///
    /// Bindings are dropped: they point at identities that would otherwise be shared with
    /// the original, and a duplicated arrow that still follows the source's target is a
    /// surprise.
    func withNewIdentity() -> AnnotationCommand {
        let newID = AnnotationID()
        switch self {
        case var .arrow(spec):
            spec.id = newID
            spec.startBinding = nil
            spec.endBinding = nil
            return .arrow(spec)
        case var .shape(spec):
            spec.id = newID
            return .shape(spec)
        case var .line(spec):
            spec.id = newID
            return .line(spec)
        case var .freehand(spec):
            spec.id = newID
            return .freehand(spec)
        case var .highlighter(spec):
            spec.id = newID
            return .highlighter(spec)
        case var .text(spec):
            spec.id = newID
            return .text(spec)
        case var .redaction(spec):
            spec.id = newID
            return .redaction(spec)
        case var .counter(spec):
            spec.id = newID
            return .counter(spec)
        case var .measure(spec):
            spec.id = newID
            return .measure(spec)
        case var .image(spec):
            spec.id = newID
            return .image(spec)
        default:
            return self
        }
    }
}
