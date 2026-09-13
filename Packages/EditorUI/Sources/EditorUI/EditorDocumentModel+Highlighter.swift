import AnnotationModel
import CoreGraphics
import Foundation
import Shared

/// Smart highlighter: Vision word boxes snap, ⌘ disables, click places a book-style
/// stroke sized to the text (docs/03 §3 P2, CleanShot §8).
@MainActor
extension EditorDocumentModel {
    /// How far the pointer may wander before a click-to-highlight becomes a freehand drag.
    static let smartHighlightDragSlop: CGFloat = 2

    /// Stages OCR layout for snapping. Safe to call more than once.
    public func loadHighlightLayout(from analysis: VisionAnalysis) {
        recognizedLines = analysis.lines
        recognizedWords = analysis.words
        highlightBoxes = analysis.highlightBoxes(in: document.baseImage.size)
    }

    /// The smallest box under the pointer, or nil when snapping is off or nothing is there.
    public func highlightTarget(at point: CGPoint, modifiers: EditorModifiers = []) -> CGRect? {
        guard tool == .highlighter else { return nil }
        guard !modifiers.contains(.extendSelection) else { return nil }
        let hits = highlightBoxes.filter { $0.contains(point) }
        return hits.min { $0.width * $0.height < $1.width * $1.height }
    }

    /// Hover preview while the highlighter is armed and no stroke is in progress.
    public func pointerMoved(to point: CGPoint, modifiers: EditorModifiers = []) {
        guard tool == .highlighter, dragOrigin == nil else {
            if hoveredHighlightBox != nil {
                hoveredHighlightBox = nil
            }
            return
        }
        hoveredHighlightBox = highlightTarget(at: point, modifiers: modifiers)
    }

    /// Starts a snapped highlight if the pointer is on text. Returns true when it did.
    func beginSmartHighlight(at point: CGPoint, modifiers: EditorModifiers) -> Bool {
        guard let box = highlightTarget(at: point, modifiers: modifiers) else { return false }
        pendingSmartHighlight = box
        hoveredHighlightBox = box
        return true
    }

    /// Converts a click-to-highlight into a freehand stroke once the pointer moves.
    func continueSmartHighlightDrag(to point: CGPoint, modifiers: EditorModifiers) -> Bool {
        guard let origin = dragOrigin, pendingSmartHighlight != nil else { return false }
        let distance = hypot(point.x - origin.x, point.y - origin.y)
        guard distance >= Self.smartHighlightDragSlop else { return true }

        pendingSmartHighlight = nil
        hoveredHighlightBox = nil
        guard let annotationTool = tool.annotation,
              var stroke = makeDraft(annotationTool, at: origin)
        else {
            return false
        }
        update(&stroke, from: origin, to: point, modifiers: modifiers)
        draft = stroke
        return true
    }

    /// Places a book-style highlight over the snapped box. False when this was a drag.
    func commitSmartHighlight() -> Bool {
        guard let box = pendingSmartHighlight else { return false }
        pendingSmartHighlight = nil
        hoveredHighlightBox = nil
        placeSmartHighlight(over: box)
        return true
    }

    /// A horizontal stroke through the box, width matching the text height.
    func placeSmartHighlight(over box: CGRect) {
        var stroke = styleMemory.stroke(for: .highlighter)
        stroke.width = min(
            max(box.height * 1.15, StrokeStyle.widthRange.lowerBound),
            StrokeStyle.widthRange.upperBound
        )
        let command = AnnotationCommand.highlighter(HighlighterSpec(
            points: [
                CGPoint(x: box.minX, y: box.midY),
                CGPoint(x: box.maxX, y: box.midY)
            ],
            stroke: stroke
        ))
        document.add(command)
        document.selection = [command.id]
        // Width is sized to this word; the inspector's memory stays the user's choice.
    }
}
