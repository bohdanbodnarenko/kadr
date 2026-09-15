import AnnotationModel
import CoreGraphics
import Foundation

/// Pointer-down/drag/up for every tool, including select-mode move and marquee.
///
/// Resize is a sibling gesture in `EditorDocumentModel+Resize.swift`; both share the
/// drag origin and the one-undo-step contract (docs/07 C2, docs/09 U0.2).
@MainActor
public extension EditorDocumentModel {
    func pointerDown(
        at point: CGPoint,
        modifiers: EditorModifiers = [],
        grabbing: SelectionHandle? = nil,
        cropGrabbing: CropHandle? = nil,
        handleTolerance: CGFloat = SelectionResizer.hitRadius
    ) {
        endInspectorStyleEdit()
        dragOrigin = point

        if tool == .crop {
            beginCropDrag(at: point, grabbing: cropGrabbing, handleTolerance: handleTolerance)
            return
        }

        if beginSmartHighlight(at: point, modifiers: modifiers) {
            return
        }

        guard let annotationTool = tool.annotation else {
            if beginResizeIfHandle(
                at: point,
                grabbing: grabbing,
                modifiers: modifiers,
                tolerance: handleTolerance
            ) {
                return
            }
            beginSelectionDrag(at: point, modifiers: modifiers)
            // A corner of what we just selected is a resize, not a move: otherwise the
            // first click on a newly drawn shape's corner always drags the whole thing.
            if beginResizeIfHandle(
                at: point,
                grabbing: nil,
                modifiers: modifiers,
                tolerance: handleTolerance
            ) {
                isMovingSelection = false
            }
            return
        }

        if tool.isClickToPlace {
            if beginDragOfExistingClickToPlace(at: point) {
                return
            }
            place(annotationTool, at: point)
            return
        }
        draft = makeDraft(annotationTool, at: snappedIfMeasuring(point))
    }

    func pointerDragged(to point: CGPoint, modifiers: EditorModifiers = []) {
        guard let origin = dragOrigin else { return }

        if continueSmartHighlightDrag(to: point, modifiers: modifiers) {
            return
        }

        if resizeHandle != nil {
            dragResize(to: point, from: origin, modifiers: modifiers)
            return
        }
        if isMovingSelection {
            dragSelection(to: point, from: origin, modifiers: modifiers)
            return
        }

        if tool == .select {
            marquee = CGRect(
                x: min(origin.x, point.x),
                y: min(origin.y, point.y),
                width: abs(origin.x - point.x),
                height: abs(origin.y - point.y)
            )
            return
        }

        if tool == .crop {
            dragCrop(to: point, from: origin, modifiers: modifiers)
            return
        }

        guard var draft else { return }
        update(&draft, from: origin, to: snappedIfMeasuring(point), modifiers: modifiers)
        self.draft = draft
    }

    func pointerUp(at point: CGPoint, modifiers: EditorModifiers = []) {
        defer {
            // Closes the drag's single undo step. Safe unconditionally: with no gesture
            // open it does nothing, so every exit from this method leaves history tidy.
            commitResize()
            document.endGesture()
            dragOrigin = nil
            dragStartCommands = [:]
            dragDependents = []
            isMovingSelection = false
            resizeHandle = nil
            resizeStartBounds = nil
            cropDragHandle = nil
            cropDragStartRect = nil
            pendingSmartHighlight = nil
            hoveredHighlightBox = nil
            marquee = nil
            draft = nil
        }

        if commitSmartHighlight() {
            return
        }

        if tool == .select {
            if let marquee {
                let enclosed = AnnotationHitTesting.enclosed(in: document.commands, by: marquee)
                let ids = Set(enclosed.map(\.id))
                document.selection = modifiers.contains(.extendSelection)
                    ? document.selection.union(ids)
                    : ids
            }
            return
        }

        // A click with the measure tool and no drag means "measure the thing under the
        // pointer" — the edge-snap payoff (docs/06 M21).
        if let box = measurementForClick(on: draft) {
            document.add(box)
            document.selection = [box.id]
            return
        }

        guard let draft, Self.isWorthKeeping(draft) else { return }
        document.add(bindingArrowEnds(of: draft))
        document.selection = [draft.id]
        rememberStyle(of: draft)
        finishAppliedTool(placed: draft.id)
    }

    /// A click on an already-placed badge (or sticker) drags it rather than stacking
    /// another on the same spot — the user meant the one they can see.
    private func beginDragOfExistingClickToPlace(at point: CGPoint) -> Bool {
        guard let expected = tool.annotation,
              let hit = AnnotationHitTesting.topmost(in: document.commands, at: point),
              hit.tool == expected
        else { return false }

        document.selection = [hit.id]
        guard !isCanvasLocked else { return true }
        dragStartCommands = [hit.id: hit]
        captureArrowDependents()
        isMovingSelection = true
        document.beginGesture()
        return true
    }

    private func beginSelectionDrag(at point: CGPoint, modifiers: EditorModifiers) {
        guard let hit = AnnotationHitTesting.topmost(in: document.commands, at: point) else {
            if beginMoveFromSelectionInterior(at: point, modifiers: modifiers) {
                return
            }
            if !modifiers.contains(.extendSelection) {
                document.selection = []
            }
            return
        }

        if modifiers.contains(.extendSelection) {
            document.selection.formSymmetricDifference([hit.id])
        } else if !document.selection.contains(hit.id) {
            document.selection = [hit.id]
        }

        guard !isCanvasLocked else { return }

        isMovingSelection = !document.selection.isEmpty
        guard isMovingSelection else { return }

        dragStartCommands = Dictionary(
            uniqueKeysWithValues: document.commands
                .filter { document.selection.contains($0.id) }
                .map { ($0.id, $0) }
        )
        captureArrowDependents()
        // One undo step for the whole drag, however many frames it takes (docs/09 U0.2).
        document.beginGesture()
    }

    /// Positions the selection for the pointer's current location.
    ///
    /// Absolute, not incremental: every event re-derives each annotation from where it
    /// was when the drag started, so a 100-point drag moves exactly 100 points no matter
    /// how many mouse-moved events arrived on the way.
    private func dragSelection(to point: CGPoint, from origin: CGPoint, modifiers: EditorModifiers = []) {
        var delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        if modifiers.contains(.constrain) {
            if abs(delta.width) >= abs(delta.height) {
                delta.height = 0
            } else {
                delta.width = 0
            }
        }
        let starts = dragStartCommands
        guard !starts.isEmpty else { return }

        document.updateGesture { commands in
            for index in commands.indices {
                guard let start = starts[commands[index].id] else { continue }
                commands[index] = Self.translated(start, by: delta)
            }
        }
    }

    /// A drag from empty space inside the selection's union moves it (docs/16 ED-12).
    private func beginMoveFromSelectionInterior(at point: CGPoint, modifiers: EditorModifiers) -> Bool {
        guard !modifiers.contains(.extendSelection), !document.selection.isEmpty, !isCanvasLocked else {
            return false
        }
        let selected = document.commands.filter { document.selection.contains($0.id) }
        if selected.count == 1 {
            switch selected[0] {
            case .arrow, .line, .measure: return false
            default: break
            }
        }
        guard SelectionResizer.unionBounds(of: selected).contains(point) else { return false }
        isMovingSelection = true
        dragStartCommands = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        captureArrowDependents()
        document.beginGesture()
        return true
    }
}
