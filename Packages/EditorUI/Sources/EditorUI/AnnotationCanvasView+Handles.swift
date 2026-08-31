import AnnotationModel
import AppKit
import QuartzCore

/// Selection chrome: a dashed frame, eight box anchors, or path terminals for arrows.
extension AnnotationCanvasView {
    /// Screen-constant size: layers live in image space, magnification scales the view.
    var handleViewScale: CGFloat {
        max(enclosingScrollView?.magnification ?? 1, 0.05)
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
        guard model.tool == .select else { return }
        let hit = SelectionResizer.hitRadius / handleViewScale
        for (handle, point) in SelectionResizer.anchors(for: model.selectedCommands) {
            let canvas = model.document.canvasPoint(fromImage: point)
            addCursorRect(
                CGRect(x: canvas.x - hit, y: canvas.y - hit, width: hit * 2, height: hit * 2),
                cursor: cursor(for: handle)
            )
        }
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
            let size = handle.isCorner
                ? SelectionResizer.cornerSize / handleViewScale
                : SelectionResizer.edgeSize / handleViewScale
            selectionLayer.addSublayer(handleSquare(at: point, size: size))
        }
    }

    private func addPathHandles(_ anchors: [(SelectionHandle, CGPoint)]) {
        let size = SelectionResizer.cornerSize / handleViewScale
        for (_, point) in anchors {
            selectionLayer.addSublayer(handleCircle(at: point, size: size))
        }
    }

    private func handleSquare(at point: CGPoint, size: CGFloat) -> CALayer {
        let handle = CALayer()
        handle.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        handle.backgroundColor = NSColor.white.cgColor
        handle.borderColor = NSColor.controlAccentColor.cgColor
        handle.borderWidth = 1 / handleViewScale
        handle.cornerRadius = 1 / handleViewScale
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
