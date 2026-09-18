import AnnotationModel
import CoreGraphics
import Foundation

/// Grabbing a selection handle and dragging it (docs/03 §3).
///
/// Split from the model's own file because move and resize are different gestures that
/// share a drag origin, and because the resize arithmetic already lives in AnnotationModel.
@MainActor
extension EditorDocumentModel {
    /// Starts a resize when the pointer is on a handle of the current selection.
    ///
    /// Handles are tested before the body: a corner sits on the annotation, and grabbing
    /// it must resize, not move. ⌘-click skips this so adding to the selection still works.
    func beginResizeIfHandle(
        at point: CGPoint,
        grabbing explicit: SelectionHandle? = nil,
        modifiers: EditorModifiers,
        tolerance: CGFloat
    ) -> Bool {
        guard tool == .select, !isCanvasLocked, !modifiers.contains(.extendSelection) else { return false }
        let selected = selectedCommands
        guard !selected.isEmpty else { return false }
        // Screen-space hits from the canvas win: they stay a constant size at every zoom,
        // which is how Screendrop keeps corners grabable on a fitted 5K capture.
        let handle = explicit ?? SelectionResizer.handle(at: point, in: selected, tolerance: tolerance)
        guard let handle else { return false }

        resizeHandle = handle
        resizeStartBounds = SelectionResizer.unionBounds(of: selected)
        dragStartCommands = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        captureArrowDependents()
        document.beginGesture()
        return true
    }

    func dragResize(to point: CGPoint, from origin: CGPoint, modifiers: EditorModifiers) {
        guard let handle = resizeHandle else { return }
        if handle.isPath {
            dragPathHandle(handle, to: point, modifiers: modifiers)
            return
        }
        if handle.isRotate {
            dragRotateHandle(to: point, from: origin, modifiers: modifiers)
            return
        }
        dragBoxHandle(handle, to: point, from: origin, modifiers: modifiers)
    }

    private func dragRotateHandle(to point: CGPoint, from origin: CGPoint, modifiers: EditorModifiers) {
        guard let startBounds = resizeStartBounds else { return }
        let center = CGPoint(x: startBounds.midX, y: startBounds.midY)
        let startAngle = atan2(origin.y - center.y, origin.x - center.x)
        let currentAngle = atan2(point.y - center.y, point.x - center.x)
        var delta = currentAngle - startAngle
        if modifiers.contains(.constrain) {
            delta = AnnotationRotation.snap(delta)
        }
        let starts = dragStartCommands
        document.updateGesture { commands in
            for index in commands.indices {
                guard let start = starts[commands[index].id] else { continue }
                commands[index] = start.applying(rotation: start.rotation + delta)
            }
        }
    }

    var selectedCommands: [AnnotationCommand] {
        document.commands.filter { document.selection.contains($0.id) && $0.isSelectable }
    }

    func commitResize() {
        if case .arrow = dragStartCommands.values.first, resizeHandle?.isPath == true {
            rebindResizedArrow()
        }
    }

    private func dragBoxHandle(
        _ handle: SelectionHandle,
        to point: CGPoint,
        from origin: CGPoint,
        modifiers: EditorModifiers
    ) {
        guard case let .box(cropHandle) = handle, let startBounds = resizeStartBounds else { return }
        if let start = dragStartCommands.values.first, dragStartCommands.count == 1,
           let oriented = OrientedSelection([start]) {
            let drag = OrientedSelection.Drag(handle: cropHandle, from: origin, to: point)
            dragOrientedHandle(drag, of: start, oriented: oriented, modifiers: modifiers)
            return
        }
        let translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        let aspect: CGFloat? = if shouldLockAspect(handle: cropHandle, modifiers: modifiers) {
            startBounds.height > 0 ? startBounds.width / startBounds.height : nil
        } else {
            nil
        }
        let newBounds = CropRectEditor.resized(
            startBounds,
            handle: cropHandle,
            translation: translation,
            aspect: aspect
        )
        let starts = dragStartCommands
        let widthOnly = handle.isWidthOnly
        document.updateGesture { commands in
            for index in commands.indices {
                guard let start = starts[commands[index].id] else { continue }
                commands[index] = SelectionResizer.scaled(
                    start,
                    from: startBounds,
                    to: newBounds,
                    widthOnly: widthOnly
                )
            }
        }
    }

    /// A lone rotated annotation resizes in its own axes, its opposite side held still.
    private func dragOrientedHandle(
        _ drag: OrientedSelection.Drag,
        of start: AnnotationCommand,
        oriented: OrientedSelection,
        modifiers: EditorModifiers
    ) {
        var drag = drag
        let box = oriented.box
        if shouldLockAspect(handle: drag.handle, modifiers: modifiers), box.height > 0 {
            drag.aspect = box.width / box.height
        }
        let resized = oriented.resized(start, by: drag)
        let id = start.id
        document.updateGesture { commands in
            guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
            commands[index] = resized
        }
    }

    /// ⇧ on a corner holds the aspect. A lone counter is always a circle, so it locks
    /// even without ⇧ — stretching a badge into an ellipse is never what was meant.
    private func shouldLockAspect(handle: CropHandle, modifiers: EditorModifiers) -> Bool {
        if selectedCommands.count == 1, case .counter = selectedCommands.first {
            return true
        }
        return modifiers.contains(.constrain) && handle.isCorner
    }

    // MARK: - Path

    private func dragPathHandle(_ handle: SelectionHandle, to point: CGPoint, modifiers: EditorModifiers) {
        let starts = dragStartCommands
        guard starts.count == 1, let (id, start) = starts.first else { return }
        let origin: CGPoint? = if modifiers.contains(.constrain), handle != .pathMiddle {
            pathAnchor(of: start, moving: handle)
        } else {
            nil
        }
        document.updateGesture { commands in
            guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
            commands[index] = SelectionResizer.draggingPath(
                start,
                handle: handle,
                to: point,
                constrainFrom: origin
            )
        }
    }

    private func pathAnchor(of command: AnnotationCommand, moving handle: SelectionHandle) -> CGPoint? {
        switch command {
        case let .arrow(spec):
            handle == .pathEnd ? spec.start : spec.end
        case let .line(spec):
            handle == .pathEnd ? spec.start : spec.end
        case let .measure(spec):
            handle == .pathEnd ? spec.start : spec.end
        default:
            nil
        }
    }

    private func rebindResizedArrow() {
        guard let id = dragStartCommands.keys.first,
              let command = document.command(id),
              case .arrow = command
        else {
            return
        }
        let bound = bindingArrowEnds(of: command)
        guard bound != command else { return }
        document.updateGesture { commands in
            guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
            commands[index] = bound
        }
    }
}
