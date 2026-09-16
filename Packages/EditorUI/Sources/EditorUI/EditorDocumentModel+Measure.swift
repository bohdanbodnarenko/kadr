import AnnotationModel
import CoreGraphics
import Foundation
import Shared

/// The measure tool, and the geometry every tool shares (docs/03 §3 P3, docs/06 M21).
///
/// Split out of `EditorDocumentModel` so the gesture state machine stays the file a reader
/// opens to understand the editor, and the pixel-ruler behaviour — snapping, enclosing
/// boxes, edge detection — reads on its own.
extension EditorDocumentModel {
    // MARK: - Measuring (docs/06 M21)

    /// Pulls a point onto a nearby detected line, while the measure tool is active.
    ///
    /// Only the measure tool: a measurement that lands two pixels off the border it is
    /// measuring is wrong, whereas an arrow that snaps to something the user did not aim
    /// at is just annoying.
    func snappedIfMeasuring(_ point: CGPoint) -> CGPoint {
        guard tool == .measure else { return point }
        return snappedToEdges(point)
    }

    /// The nearest detected line to each axis of `point`, in base-image points.
    public func snappedToEdges(_ point: CGPoint) -> CGPoint {
        guard !edgeCandidates.isEmpty, edgeSnapTolerance > 0 else { return point }
        let scale = document.baseImage.scale
        let tolerance = Int((edgeSnapTolerance * scale).rounded())
        let pixelX = Int((point.x * scale).rounded())
        let pixelY = Int((point.y * scale).rounded())

        let snappedX = EdgeSnapper.snapped(pixelX, to: edgeCandidates.verticalEdges, tolerance: tolerance)
        let snappedY = EdgeSnapper.snapped(pixelY, to: edgeCandidates.horizontalEdges, tolerance: tolerance)
        return CGPoint(
            x: snappedX.map { CGFloat($0) / scale } ?? point.x,
            y: snappedY.map { CGFloat($0) / scale } ?? point.y
        )
    }

    /// The measurement a click with no drag should produce, if any.
    ///
    /// A click is only a measurement when there is something to snap to; otherwise a
    /// stray click would drop an arbitrary box on the canvas.
    func measurementForClick(on draft: AnnotationCommand?) -> AnnotationCommand? {
        guard let draft, case let .measure(spec) = draft, !Self.isWorthKeeping(draft) else {
            return nil
        }
        return measuredBox(around: spec.start)
    }

    /// A box measurement of whatever the detected lines enclose around a point.
    func measuredBox(around point: CGPoint) -> AnnotationCommand? {
        guard !edgeCandidates.isEmpty else { return nil }
        let scale = document.baseImage.scale
        guard let pixels = EdgeSnapper.enclosingRect(
            aroundX: Int((point.x * scale).rounded()),
            y: Int((point.y * scale).rounded()),
            in: edgeCandidates
        ) else {
            return nil
        }
        return .measure(MeasureSpec(
            start: CGPoint(x: CGFloat(pixels.x) / scale, y: CGFloat(pixels.y) / scale),
            end: CGPoint(
                x: CGFloat(pixels.x + pixels.width) / scale,
                y: CGFloat(pixels.y + pixels.height) / scale
            ),
            measuresBox: true,
            stroke: styleMemory.stroke(for: .measure)
        ))
    }

    /// Reads the base image's straight edges once, so the measure tool can snap to them.
    func loadEdges(from image: CGImage) {
        edgeCandidates = EdgeDetector.candidates(in: image)
    }

    /// The same, off the main actor (docs/10 R1).
    ///
    /// Detection is a pass over every pixel of the capture, and it used to run inline in
    /// the mouse-down of the first measurement — a visible hitch exactly as the user starts
    /// to drag. Until it lands nothing snaps, which is what an empty set already means.
    func loadEdgesInBackground(from image: CGImage) {
        guard edgeCandidates.isEmpty, !isLoadingEdges else { return }
        isLoadingEdges = true
        Task { [weak self] in
            let candidates = await Task.detached(priority: .userInitiated) {
                EdgeDetector.candidates(in: image)
            }.value
            guard let self else { return }
            isLoadingEdges = false
            if edgeCandidates.isEmpty {
                edgeCandidates = candidates
            }
        }
    }

    /// Moves an annotation, whatever its geometry.
    static func translated(_ command: AnnotationCommand, by delta: CGSize) -> AnnotationCommand {
        translatedPoints(command, by: delta) ?? translatedRects(command, by: delta)
    }

    /// The annotations defined by points rather than by a rectangle.
    private static func translatedPoints(
        _ command: AnnotationCommand,
        by delta: CGSize
    ) -> AnnotationCommand? {
        func move(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + delta.width, y: point.y + delta.height)
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
        case var .counter(spec):
            spec.center = move(spec.center)
            return .counter(spec)
        case var .measure(spec):
            spec.start = move(spec.start)
            spec.end = move(spec.end)
            return .measure(spec)
        default:
            return nil
        }
    }

    /// The annotations defined by a rectangle. Beautify is the canvas itself and does not
    /// move with a selection.
    private static func translatedRects(
        _ command: AnnotationCommand,
        by delta: CGSize
    ) -> AnnotationCommand {
        func move(_ rect: CGRect) -> CGRect {
            rect.offsetBy(dx: delta.width, dy: delta.height)
        }

        switch command {
        case var .shape(spec):
            spec.rect = move(spec.rect)
            return .shape(spec)
        case var .text(spec):
            spec.rect = move(spec.rect)
            return .text(spec)
        case var .redaction(spec):
            spec.rect = move(spec.rect)
            return .redaction(spec)
        case var .spotlight(spec):
            spec.rect = move(spec.rect)
            return .spotlight(spec)
        case var .crop(spec):
            spec.rect = move(spec.rect)
            return .crop(spec)
        case var .image(spec):
            spec.rect = move(spec.rect)
            return .image(spec)
        default:
            return command
        }
    }
}
