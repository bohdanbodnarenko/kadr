import AnnotationModel
import CoreGraphics
import Foundation

/// Drafting and drag geometry. Split from the model type so the gesture state machine
/// stays readable, and so the per-tool switches stay under the complexity budget.
extension EditorDocumentModel {
    func makeDraft(_ annotationTool: AnnotationTool, at point: CGPoint) -> AnnotationCommand? {
        pathDraft(annotationTool, at: point) ?? boxDraft(annotationTool, at: point)
    }

    func update(
        _ draft: inout AnnotationCommand,
        from origin: CGPoint,
        to point: CGPoint,
        modifiers: EditorModifiers
    ) {
        if updatePath(&draft, from: origin, to: point, modifiers: modifiers) {
            return
        }
        updateBox(&draft, from: origin, to: point, modifiers: modifiers)
    }

    // swiftlint:disable:next cyclomatic_complexity
    func rememberStyle(of command: AnnotationCommand) {
        switch command {
        case let .arrow(spec):
            styleMemory.remember(spec.stroke, for: .arrow)
            styleMemory.lastArrowHead = spec.head
            styleMemory.lastStartArrowHead = spec.startHead
        case let .shape(spec):
            styleMemory.remember(spec.stroke, for: .shape)
            styleMemory.remember(spec.fill, for: .shape)
            styleMemory.lastShapeKind = spec.kind
        case let .line(spec):
            styleMemory.remember(spec.stroke, for: .line)
        case let .freehand(spec):
            styleMemory.remember(spec.stroke, for: .freehand)
        case let .highlighter(spec):
            styleMemory.remember(spec.stroke, for: .highlighter)
        case let .text(spec):
            styleMemory.lastTextStyle = spec.style
        case let .redaction(spec):
            styleMemory.lastRedactionStyle = spec.style
        case let .spotlight(spec):
            styleMemory.lastSpotlightDimOpacity = spec.dimOpacity
            styleMemory.lastSpotlightCornerRadius = spec.cornerRadius
        case let .measure(spec):
            styleMemory.remember(spec.stroke, for: .measure)
            styleMemory.lastMeasuresBox = spec.measuresBox
        case let .counter(spec):
            styleMemory.lastCounterNumbering = spec.numberingStyle
            styleMemory.lastCounterSize = CounterBadgeSize.matching(spec.radius)
            styleMemory.lastCounterFill = spec.fill
        case .crop, .beautify, .camera, .progressiveBlur, .watermark, .subjectLift, .image:
            break
        }
    }

    /// A rect from a drag, honouring ⇧ (square) and ⌥ (from the centre).
    static func rect(from origin: CGPoint, to point: CGPoint, modifiers: EditorModifiers) -> CGRect {
        var corner = point
        if modifiers.contains(.constrain) {
            let side = max(abs(point.x - origin.x), abs(point.y - origin.y))
            corner = CGPoint(
                x: origin.x + (point.x >= origin.x ? side : -side),
                y: origin.y + (point.y >= origin.y ? side : -side)
            )
        }
        if modifiers.contains(.fromCenter) {
            return CGRect(
                x: origin.x - abs(corner.x - origin.x),
                y: origin.y - abs(corner.y - origin.y),
                width: abs(corner.x - origin.x) * 2,
                height: abs(corner.y - origin.y) * 2
            )
        }
        return CGRect(
            x: min(origin.x, corner.x),
            y: min(origin.y, corner.y),
            width: abs(corner.x - origin.x),
            height: abs(corner.y - origin.y)
        )
    }

    /// ⇧ on a line or arrow snaps to the nearest 45°.
    static func snapped(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// Whether a finished drag actually drew something.
    ///
    /// A click with no drag leaves a zero-sized annotation. Testing the *geometry* rather
    /// than the bounding box matters: a bounding box includes the stroke, so a zero-sized
    /// shape with a four-point stroke looks non-empty and would be kept.
    static func isWorthKeeping(_ command: AnnotationCommand) -> Bool {
        let minimum: CGFloat = 2
        if let length = pathLength(command) {
            return length >= minimum
        }
        if let rect = boxRect(command) {
            return command.tool == .shape
                ? (rect.width >= minimum || rect.height >= minimum)
                : (rect.width >= minimum && rect.height >= minimum)
        }
        if let count = strokePointCount(command) {
            return count > 1
        }
        return true
    }

    private func pathDraft(_ annotationTool: AnnotationTool, at point: CGPoint) -> AnnotationCommand? {
        let stroke = styleMemory.stroke(for: annotationTool)
        switch annotationTool {
        case .arrow:
            return .arrow(ArrowSpec(
                start: point,
                end: point,
                head: styleMemory.lastArrowHead,
                startHead: styleMemory.lastStartArrowHead,
                stroke: stroke
            ))
        case .line:
            return .line(LineSpec(start: point, end: point, stroke: stroke))
        case .freehand:
            return .freehand(FreehandSpec(points: [point], stroke: stroke))
        case .highlighter:
            return .highlighter(HighlighterSpec(points: [point], stroke: stroke))
        case .measure:
            return .measure(MeasureSpec(
                start: point,
                end: point,
                measuresBox: styleMemory.lastMeasuresBox,
                stroke: stroke
            ))
        default:
            return nil
        }
    }

    private func boxDraft(_ annotationTool: AnnotationTool, at point: CGPoint) -> AnnotationCommand? {
        let stroke = styleMemory.stroke(for: annotationTool)
        switch annotationTool {
        case .shape:
            return .shape(ShapeSpec(
                kind: styleMemory.lastShapeKind,
                rect: CGRect(origin: point, size: .zero),
                stroke: stroke,
                fill: styleMemory.fill(for: .shape)
            ))
        case .text:
            return .text(TextSpec(
                rect: CGRect(origin: point, size: CGSize(width: 200, height: 40)),
                style: styleMemory.lastTextStyle
            ))
        case .redaction:
            return .redaction(RedactionSpec(
                rect: CGRect(origin: point, size: .zero),
                style: styleMemory.lastRedactionStyle
            ))
        case .spotlight:
            return .spotlight(SpotlightSpec(
                rect: CGRect(origin: point, size: .zero),
                dimOpacity: styleMemory.lastSpotlightDimOpacity,
                cornerRadius: styleMemory.lastSpotlightCornerRadius
            ))
        case .crop:
            return .crop(CropSpec(rect: CGRect(origin: point, size: .zero)))
        default:
            return nil
        }
    }

    private func updatePath(
        _ draft: inout AnnotationCommand,
        from origin: CGPoint,
        to point: CGPoint,
        modifiers: EditorModifiers
    ) -> Bool {
        let end = modifiers.contains(.constrain) ? Self.snapped(point, from: origin) : point
        switch draft {
        case var .arrow(spec):
            spec.end = end
            draft = .arrow(spec)
        case var .line(spec):
            spec.end = end
            draft = .line(spec)
        case var .measure(spec):
            spec.end = end
            draft = .measure(spec)
        case var .freehand(spec):
            spec.points.append(point)
            draft = .freehand(spec)
        case var .highlighter(spec):
            spec.points.append(point)
            draft = .highlighter(spec)
        default:
            return false
        }
        return true
    }

    private func updateBox(
        _ draft: inout AnnotationCommand,
        from origin: CGPoint,
        to point: CGPoint,
        modifiers: EditorModifiers
    ) {
        let rect = Self.rect(from: origin, to: point, modifiers: modifiers)
        switch draft {
        case var .shape(spec):
            spec.rect = rect
            draft = .shape(spec)
        case var .redaction(spec):
            spec.rect = rect
            draft = .redaction(spec)
        case var .spotlight(spec):
            spec.rect = rect
            draft = .spotlight(spec)
        case var .crop(spec):
            spec.rect = rect
            draft = .crop(spec)
        case var .text(spec):
            spec.rect = rect
            draft = .text(spec)
        default:
            break
        }
    }

    private static func pathLength(_ command: AnnotationCommand) -> CGFloat? {
        switch command {
        case let .arrow(spec):
            hypot(spec.end.x - spec.start.x, spec.end.y - spec.start.y)
        case let .line(spec):
            hypot(spec.end.x - spec.start.x, spec.end.y - spec.start.y)
        case let .measure(spec):
            spec.length
        default:
            nil
        }
    }

    private static func boxRect(_ command: AnnotationCommand) -> CGRect? {
        switch command {
        case let .shape(spec): spec.rect
        case let .redaction(spec): spec.rect
        case let .spotlight(spec): spec.rect
        case let .crop(spec): spec.rect
        default: nil
        }
    }

    private static func strokePointCount(_ command: AnnotationCommand) -> Int? {
        switch command {
        case let .freehand(spec): spec.points.count
        case let .highlighter(spec): spec.points.count
        default: nil
        }
    }
}
