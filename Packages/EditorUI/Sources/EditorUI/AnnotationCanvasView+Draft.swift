import AnnotationModel
import AnnotationRender
import AppKit
import QuartzCore

/// The annotation being drawn, before it is committed (docs/03 §3).
///
/// Its own file because it is the per-event hot path of every drawing tool, and because the
/// freehand stroke keeps state of its own between events (docs/10 R1).
extension AnnotationCanvasView {
    /// Refreshes the live drag preview: one layer, replaced only when the kind changes.
    func updateDraftLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let draft = model.draft else {
            draftShapeLayer?.removeFromSuperlayer()
            draftShapeLayer = nil
            resetDraftPath()
            updateBindingHint()
            return
        }

        let scale = window?.backingScaleFactor ?? 2
        if let existing = draftShapeLayer, existing.name == draft.id.rawValue.uuidString {
            if !extendDraftStroke(draft, on: existing) {
                AnnotationLayerFactory.update(
                    existing,
                    for: draft,
                    context: layerContext(canvasRect: model.document.canvasRect, isLive: true)
                )
            }
        } else {
            draftShapeLayer?.removeFromSuperlayer()
            resetDraftPath()
            draftShapeLayer = AnnotationLayerFactory.makeLayer(
                for: draft,
                contentsScale: scale,
                context: layerContext(canvasRect: model.document.canvasRect, isLive: true)
            )
            if let layer = draftShapeLayer {
                draftLayer.addSublayer(layer)
            }
        }
        updateBindingHint()
    }

    /// Appends a freehand or highlighter draft's new points to its path, instead of
    /// rebuilding the polyline. Returns false for every other kind of draft.
    private func extendDraftStroke(_ draft: AnnotationCommand, on layer: CALayer) -> Bool {
        let points: [CGPoint]
        switch draft {
        case let .freehand(spec): points = spec.points
        case let .highlighter(spec): points = spec.points
        default: return false
        }
        guard let shape = layer as? CAShapeLayer else { return false }

        if draftPathID != draft.id || points.count < draftPathPointCount {
            resetDraftPath()
        }
        let path = draftPath ?? CGMutablePath()
        var start = draftPathPointCount
        if start == 0, let first = points.first {
            path.move(to: first)
            start = 1
        }
        if start < points.count {
            for point in points[start...] {
                path.addLine(to: point)
            }
        }
        draftPath = path
        draftPathID = draft.id
        draftPathPointCount = points.count
        // A copy: Core Animation keeps the path it is handed, and this one keeps growing.
        shape.path = path.copy()
        return true
    }

    func resetDraftPath() {
        draftPath = nil
        draftPathPointCount = 0
        draftPathID = nil
    }
}
