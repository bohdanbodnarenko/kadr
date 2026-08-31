import CoreGraphics
import Foundation

/// A grab point on the current selection (docs/03 §3).
///
/// Boxes get the eight crop anchors. A lone arrow, line or length-measurement gets its
/// own terminals — a bounding box around a two-point arrow is a lie, and dragging a
/// corner of that lie is not how anyone resizes an arrow.
public enum SelectionHandle: Equatable, Sendable, Hashable {
    case box(CropHandle)
    case pathStart
    case pathEnd
    case pathMiddle

    public var isCorner: Bool {
        if case let .box(handle) = self {
            return handle.isCorner
        }
        return false
    }

    public var isWidthOnly: Bool {
        if case let .box(handle) = self {
            return handle == .leading || handle == .trailing
        }
        return false
    }

    public var isPath: Bool {
        switch self {
        case .pathStart, .pathEnd, .pathMiddle: true
        case .box: false
        }
    }
}

/// Hit-testing and geometry for selection handles (docs/03 §3).
///
/// Pure so a resize can be table-tested without a window. The canvas is only the
/// drawing and the pointer; this is the arithmetic.
public enum SelectionResizer {
    /// How big a corner square is, in view points. Divided by magnification when drawn
    /// so handles stay the same size at every zoom, the way Screendrop's do.
    public static let cornerSize: CGFloat = 8
    /// Edge anchors are slightly smaller so corners stay the primary target.
    public static let edgeSize: CGFloat = 6
    /// How close the pointer has to be, in **screen** points, to grab a handle.
    ///
    /// Screendrop uses 9. Twelve is the same idea with a slightly fatter target, because
    /// a corner click that starts a move instead of a resize is the failure mode.
    public static let hitRadius: CGFloat = 12
    /// Padding around the union bounds for the dashed outline. Handles sit on the
    /// bounds themselves — the corners the user actually aims at — the way Screendrop's do.
    public static let framePadding: CGFloat = 4

    /// The dashed frame the handles sit on.
    public static func frame(for commands: [AnnotationCommand]) -> CGRect {
        unionBounds(of: commands).insetBy(dx: -framePadding, dy: -framePadding)
    }

    public static func unionBounds(of commands: [AnnotationCommand]) -> CGRect {
        let boxes = commands.map(AnnotationHitTesting.boundingBox).filter { $0.width + $0.height > 0 }
        guard let first = boxes.first else { return .null }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Whether this selection is a single two-point annotation, which gets path handles
    /// rather than a box.
    public static func usesPathHandles(_ commands: [AnnotationCommand]) -> Bool {
        guard commands.count == 1, let command = commands.first else { return false }
        switch command {
        case .arrow, .line:
            return true
        case let .measure(spec):
            return !spec.measuresBox
        default:
            return false
        }
    }

    /// Handle locations in image space, in hit-test order (corners before edges).
    public static func anchors(for commands: [AnnotationCommand]) -> [(SelectionHandle, CGPoint)] {
        guard !commands.isEmpty else { return [] }
        if usesPathHandles(commands), let command = commands.first {
            return pathAnchors(of: command)
        }
        // On the geometry, not the padded outline: a click on a shape's visible corner
        // has to grab a handle, not start a move (Screendrop's `selectionBounds.box`).
        let box = unionBounds(of: commands)
        guard box.width > 0, box.height > 0 else { return [] }
        let corners: [CropHandle] = [.topLeading, .topTrailing, .bottomTrailing, .bottomLeading]
        let edges: [CropHandle] = [.top, .trailing, .bottom, .leading]
        return (corners + edges).map { (.box($0), $0.point(in: box)) }
    }

    /// The handle under `point`, if the pointer is close enough.
    public static func handle(
        at point: CGPoint,
        in commands: [AnnotationCommand],
        tolerance: CGFloat
    ) -> SelectionHandle? {
        anchors(for: commands).first { hypot(point.x - $0.1.x, point.y - $0.1.y) <= tolerance }?.0
    }

    /// Scales every selected annotation from `old` bounds onto `new`.
    public static func scaled(
        _ command: AnnotationCommand,
        from old: CGRect,
        to new: CGRect,
        widthOnly: Bool
    ) -> AnnotationCommand {
        scaledPoints(command, from: old, to: new)
            ?? scaledArea(command, from: old, to: new, widthOnly: widthOnly)
    }

    /// Moves one terminal of a two-point annotation.
    public static func draggingPath(
        _ command: AnnotationCommand,
        handle: SelectionHandle,
        to point: CGPoint,
        constrainFrom origin: CGPoint?
    ) -> AnnotationCommand {
        let target = origin.map { SelectionResizer.snapped(point, from: $0) } ?? point
        switch command {
        case var .arrow(spec):
            applyPath(&spec.start, &spec.end, control: &spec.controlPoint, handle: handle, to: target)
            return .arrow(spec)
        case var .line(spec):
            var unused: CGPoint?
            applyPath(&spec.start, &spec.end, control: &unused, handle: handle, to: target)
            return .line(spec)
        case var .measure(spec):
            var unused: CGPoint?
            applyPath(&spec.start, &spec.end, control: &unused, handle: handle, to: target)
            return .measure(spec)
        default:
            return command
        }
    }

    /// ⇧ on a line or arrow snaps to the nearest 45°.
    public static func snapped(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    // MARK: - Path

    static func pathAnchors(of command: AnnotationCommand) -> [(SelectionHandle, CGPoint)] {
        switch command {
        case let .arrow(spec):
            [
                (.pathStart, spec.start),
                (.pathMiddle, spec.controlPoint ?? midpoint(spec.start, spec.end)),
                (.pathEnd, spec.end)
            ]
        case let .line(spec):
            [(.pathStart, spec.start), (.pathEnd, spec.end)]
        case let .measure(spec) where !spec.measuresBox:
            [(.pathStart, spec.start), (.pathEnd, spec.end)]
        default:
            []
        }
    }

    static func midpoint(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
        CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    static func applyPath(
        _ start: inout CGPoint,
        _ end: inout CGPoint,
        control: inout CGPoint?,
        handle: SelectionHandle,
        to point: CGPoint
    ) {
        switch handle {
        case .pathStart:
            start = point
        case .pathEnd:
            end = point
        case .pathMiddle:
            let chord = midpoint(start, end)
            // Snap back to straight when the bend is a wobble, not a curve.
            if hypot(point.x - chord.x, point.y - chord.y) < 4 {
                control = nil
            } else {
                control = point
            }
        case .box:
            break
        }
    }

    // MARK: - Scale

    static func mapPoint(_ point: CGPoint, from old: CGRect, to new: CGRect) -> CGPoint {
        let scaleX = old.width > 0 ? new.width / old.width : 1
        let scaleY = old.height > 0 ? new.height / old.height : 1
        return CGPoint(
            x: new.minX + (point.x - old.minX) * scaleX,
            y: new.minY + (point.y - old.minY) * scaleY
        )
    }

    static func mapRect(_ rect: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
        let origin = mapPoint(rect.origin, from: old, to: new)
        let corner = mapPoint(CGPoint(x: rect.maxX, y: rect.maxY), from: old, to: new)
        return CGRect(
            x: min(origin.x, corner.x),
            y: min(origin.y, corner.y),
            width: abs(corner.x - origin.x),
            height: abs(corner.y - origin.y)
        )
    }

    static func scaledPoints(
        _ command: AnnotationCommand,
        from old: CGRect,
        to new: CGRect
    ) -> AnnotationCommand? {
        func move(_ point: CGPoint) -> CGPoint {
            mapPoint(point, from: old, to: new)
        }

        switch command {
        case var .arrow(spec):
            spec.start = move(spec.start)
            spec.end = move(spec.end)
            spec.controlPoint = spec.controlPoint.map(move)
            return .arrow(spec)
        case var .line(spec):
            spec.start = move(spec.start)
            spec.end = move(spec.end)
            return .line(spec)
        case var .freehand(spec):
            spec.points = spec.points.map(move)
            return .freehand(spec)
        case var .highlighter(spec):
            spec.points = spec.points.map(move)
            return .highlighter(spec)
        case var .measure(spec):
            spec.start = move(spec.start)
            spec.end = move(spec.end)
            return .measure(spec)
        case var .counter(spec):
            spec.center = move(spec.center)
            let scaleX = old.width > 0 ? abs(new.width / old.width) : 1
            let scaleY = old.height > 0 ? abs(new.height / old.height) : 1
            spec.radius = max(4, spec.radius * (scaleX + scaleY) / 2)
            return .counter(spec)
        default:
            return nil
        }
    }

    static func scaledArea(
        _ command: AnnotationCommand,
        from old: CGRect,
        to new: CGRect,
        widthOnly: Bool
    ) -> AnnotationCommand {
        switch command {
        case var .shape(spec):
            spec.rect = mapRect(spec.rect, from: old, to: new)
            return .shape(spec)
        case var .text(spec):
            spec = scaledText(spec, from: old, to: new, widthOnly: widthOnly)
            return .text(spec)
        case var .redaction(spec):
            spec.rect = mapRect(spec.rect, from: old, to: new)
            return .redaction(spec)
        case var .crop(spec):
            spec.rect = mapRect(spec.rect, from: old, to: new)
            return .crop(spec)
        case var .image(spec):
            spec.rect = mapRect(spec.rect, from: old, to: new)
            return .image(spec)
        default:
            return command
        }
    }

    static func scaledText(
        _ spec: TextSpec,
        from old: CGRect,
        to new: CGRect,
        widthOnly: Bool
    ) -> TextSpec {
        var spec = spec
        if widthOnly {
            // A side handle sets the wrap width, not the type size — the same as Screendrop.
            spec.rect.origin.x = new.minX + (spec.rect.minX - old.minX)
                * (old.width > 0 ? new.width / old.width : 1)
            spec.rect.size.width = max(24, spec.rect.width * (old.width > 0 ? new.width / old.width : 1))
            return spec
        }
        let scaleX = old.width > 0 ? abs(new.width / old.width) : 1
        let scaleY = old.height > 0 ? abs(new.height / old.height) : 1
        let uniform = (scaleX + scaleY) / 2
        spec.style.fontSize = max(4, spec.style.fontSize * uniform)
        spec.rect = mapRect(spec.rect, from: old, to: new)
        return spec
    }
}
