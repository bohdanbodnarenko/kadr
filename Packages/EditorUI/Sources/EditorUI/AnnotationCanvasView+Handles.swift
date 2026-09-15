import AnnotationModel
import AppKit
import QuartzCore

/// Selection chrome: a dashed frame, eight box anchors, or path terminals for arrows.
/// Counters keep the frame but no anchors — they are sized from the inspector.
extension AnnotationCanvasView {
    /// Screen-constant size, derived from the window transform so it stays honest when
    /// the scroll view's `magnification` is stale or missing (Screendrop's `pageToScreen`).
    var handleViewScale: CGFloat {
        let origin = convert(CGPoint.zero, to: nil)
        let unit = convert(CGPoint(x: 1, y: 0), to: nil)
        let scale = hypot(unit.x - origin.x, unit.y - origin.y)
        if scale > 0.05 {
            return scale
        }
        return max(enclosingScrollView?.magnification ?? 1, 0.05)
    }

    /// Handles around the selection, and the marquee while one is being dragged.
    func updateSelectionHandles() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        selectionLayer.sublayers?
            .filter { $0 !== marqueeLayer }
            .forEach { $0.removeFromSuperlayer() }

        let selected = model.selectedCommands
        if !selected.isEmpty {
            if SelectionResizer.usesPathHandles(selected) {
                addPathHandles(SelectionResizer.anchors(for: selected))
            } else {
                addBoxHandles(for: selected)
            }
        }

        marqueeLayer.path = model.marquee.map { CGPath(rect: $0, transform: nil) }
    }

    override public func resetCursorRects() {
        if spaceIsDown {
            addCursorRect(bounds, cursor: spacePanAnchor == nil ? NSCursor.openHand : NSCursor.closedHand)
            return
        }
        addCursorRect(bounds, cursor: canvasCursor)
        if model.tool == .crop {
            let hit = SelectionResizer.hitRadius / handleViewScale
            let rect = model.cropWorkingRect
            for handle in CropHandle.resizeHandles {
                let canvas = viewPoint(fromImage: handle.point(in: rect))
                addCursorRect(
                    CGRect(x: canvas.x - hit, y: canvas.y - hit, width: hit * 2, height: hit * 2),
                    cursor: cursor(for: handle)
                )
            }
            return
        }
        guard model.tool == .select else { return }
        let selected = model.selectedCommands
        let hit = SelectionResizer.hitRadius / handleViewScale
        for (handle, point) in SelectionResizer.anchors(for: selected) {
            let canvas = viewPoint(fromImage: point)
            addCursorRect(
                CGRect(x: canvas.x - hit, y: canvas.y - hit, width: hit * 2, height: hit * 2),
                cursor: cursor(for: handle)
            )
        }
        // Last wins when rects overlap: the disc itself is a move, not a resize.
        if let disc = counterDiscCursorRect(for: selected) {
            addCursorRect(disc, cursor: canvasCursor)
        }
    }

    /// Which handle is under the event, tested in window space so the target stays ~12pt
    /// at every zoom — the same contract as Screendrop's `handle(at: screenPoint)`.
    func screenSpaceHandle(at event: NSEvent) -> SelectionHandle? {
        let selected = model.selectedCommands
        let click = event.locationInWindow
        if isScreenSpaceCounterInterior(click, in: selected) {
            return nil
        }
        let radius = SelectionResizer.hitRadius
        for (handle, imagePoint) in SelectionResizer.anchors(for: selected) {
            let canvas = viewPoint(fromImage: imagePoint)
            let window = convert(canvas, to: nil)
            if hypot(click.x - window.x, click.y - window.y) <= radius {
                return handle
            }
        }
        return nil
    }

    private func isScreenSpaceCounterInterior(_ click: CGPoint, in commands: [AnnotationCommand]) -> Bool {
        guard commands.count == 1, case let .counter(spec) = commands.first else { return false }
        let center = convert(viewPoint(fromImage: spec.center), to: nil)
        let edge = convert(
            viewPoint(fromImage: CGPoint(x: spec.center.x + spec.radius, y: spec.center.y)),
            to: nil
        )
        let radius = hypot(edge.x - center.x, edge.y - center.y)
        return hypot(click.x - center.x, click.y - center.y) <= radius
    }

    private func counterDiscCursorRect(for commands: [AnnotationCommand]) -> CGRect? {
        guard commands.count == 1, case let .counter(spec) = commands.first else { return nil }
        let center = viewPoint(fromImage: spec.center)
        let edge = viewPoint(fromImage: CGPoint(x: spec.center.x + spec.radius, y: spec.center.y))
        let radius = hypot(edge.x - center.x, edge.y - center.y)
        return CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    private func addBoxHandles(for commands: [AnnotationCommand]) {
        let box = SelectionResizer.frame(for: commands)
        let outline = CAShapeLayer()
        outline.path = CGPath(rect: box, transform: nil)
        outline.strokeColor = NSColor.controlAccentColor.cgColor
        outline.fillColor = nil
        outline.lineWidth = 1 / handleViewScale
        outline.lineDashPattern = [3, 3]
        selectionLayer.addSublayer(outline)

        for (handle, point) in SelectionResizer.anchors(for: commands) {
            if handle.isRotate {
                selectionLayer.addSublayer(handleCircle(at: point, size: sizeForRotate))
            } else {
                let size = handle.isCorner
                    ? SelectionResizer.cornerSize / handleViewScale
                    : SelectionResizer.edgeSize / handleViewScale
                selectionLayer.addSublayer(handleSquare(at: point, size: size))
            }
        }
    }

    private var sizeForRotate: CGFloat {
        SelectionResizer.cornerSize / handleViewScale
    }

    private func addPathHandles(_ anchors: [(SelectionHandle, CGPoint)]) {
        let size = SelectionResizer.cornerSize / handleViewScale
        for (_, point) in anchors {
            selectionLayer.addSublayer(handleCircle(at: point, size: size))
        }
    }

    func handleSquare(at point: CGPoint, size: CGFloat) -> CALayer {
        let handle = CALayer()
        handle.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        handle.backgroundColor = NSColor.white.cgColor
        handle.borderColor = NSColor.controlAccentColor.cgColor
        handle.borderWidth = max(1 / handleViewScale, 0.5)
        handle.cornerRadius = 1 / handleViewScale
        handle.contentsScale = window?.backingScaleFactor ?? 2
        handle.shadowOpacity = 0.35
        handle.shadowRadius = 1 / handleViewScale
        handle.shadowOffset = .zero
        handle.shadowColor = NSColor.black.cgColor
        return handle
    }

    private func handleCircle(at point: CGPoint, size: CGFloat) -> CALayer {
        let handle = handleSquare(at: point, size: size)
        handle.cornerRadius = size / 2
        return handle
    }

    private func cursor(for handle: SelectionHandle) -> NSCursor {
        switch handle {
        case .pathStart, .pathEnd, .pathMiddle:
            NSCursor.pointingHand
        case .rotate:
            NSCursor.pointingHand
        case let .box(crop):
            cursor(for: crop)
        }
    }

    private func cursor(for handle: CropHandle) -> NSCursor {
        switch handle {
        case .top, .bottom:
            NSCursor.resizeUpDown
        case .leading, .trailing:
            NSCursor.resizeLeftRight
        case .topLeading, .bottomTrailing:
            if #available(macOS 15, *) {
                NSCursor.frameResize(position: .topLeft, directions: .all)
            } else {
                NSCursor.crosshair
            }
        case .topTrailing, .bottomLeading:
            if #available(macOS 15, *) {
                NSCursor.frameResize(position: .topRight, directions: .all)
            } else {
                NSCursor.crosshair
            }
        case .body:
            NSCursor.arrow
        }
    }
}
