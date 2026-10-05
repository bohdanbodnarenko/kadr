import AnnotationModel
import CoreGraphics
import Foundation

/// Snapping and ⌥-drag duplicate for a moving selection (docs/18 ED-7).
@MainActor
extension EditorDocumentModel {
    /// What a move snaps to: the canvas and every annotation not being moved. Read once at
    /// drag start, so the per-event cost is a few comparisons per target.
    func captureSnapTargets() {
        let moving = Set(dragStartCommands.keys)
        snapTargets = [document.contentRect] + document.commands
            .filter { !moving.contains($0.id) && !$0.tool.isCanvasChrome }
            .map(AnnotationHitTesting.boundingBox)
            .filter { $0.width + $0.height > 0 }
    }

    /// The move adjusted so the selection lands on a nearby edge or centre, and the guides
    /// to draw. ⌘ held suspends snapping, as it does for the capture overlay.
    func snappedDelta(_ delta: CGSize, modifiers: EditorModifiers) -> CGSize {
        guard !modifiers.contains(.extendSelection), snapThreshold > 0 else {
            snapGuides = []
            return delta
        }
        let start = SelectionResizer.unionBounds(of: Array(dragStartCommands.values))
        guard !start.isNull else {
            snapGuides = []
            return delta
        }
        let proposed = start.offsetBy(dx: delta.width, dy: delta.height)
        let result = SnapGuides.snap(proposed, to: snapTargets, threshold: snapThreshold)
        snapGuides = result.guides
        return CGSize(width: delta.width + result.adjustment.width, height: delta.height + result.adjustment.height)
    }

    /// ⌥ at the start of a drag leaves the originals where they are and drags copies, in the
    /// same undo step as the move.
    func duplicateSelectionForDrag() {
        let originals = document.commands.filter { document.selection.contains($0.id) }
        guard !originals.isEmpty else { return }
        let copies = originals.map { $0.withNewIdentity() }
        document.updateGesture { $0.append(contentsOf: copies) }
        document.renumberCounters()
        document.selection = Set(copies.map(\.id))
    }

    /// Where the next pasted or inserted image goes: the canvas centre, stepped down and
    /// right on each repeat so a second paste does not hide under the first.
    public func nextPastePoint() -> CGPoint {
        pasteCascadeCount += 1
        let step = 16 * CGFloat(pasteCascadeCount - 1)
        let rect = document.contentRect
        return CGPoint(x: rect.midX + step, y: rect.midY + step)
    }
}
