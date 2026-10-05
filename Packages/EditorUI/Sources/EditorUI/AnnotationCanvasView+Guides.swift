import AnnotationModel
import AppKit
import QuartzCore

/// The lines a moving selection snapped to (docs/18 ED-7).
///
/// Drawn in image space inside the draft layer, so rotate and flip carry them with
/// everything else; the stroke is one screen point at any zoom.
extension AnnotationCanvasView {
    /// Six screen points of pull, whatever the zoom.
    func prepareSnapping() {
        model.snapThreshold = 6 / max(handleViewScale, 0.05)
    }

    func updateSnapGuides() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let guides = model.snapGuides
        guard !guides.isEmpty else {
            guideLayer?.removeFromSuperlayer()
            guideLayer = nil
            return
        }
        let layer = guideLayer ?? makeGuideLayer()
        let bounds = model.document.canvasRect
        let path = CGMutablePath()
        for guide in guides {
            switch guide.axis {
            case .vertical:
                path.move(to: CGPoint(x: guide.position, y: bounds.minY))
                path.addLine(to: CGPoint(x: guide.position, y: bounds.maxY))
            case .horizontal:
                path.move(to: CGPoint(x: bounds.minX, y: guide.position))
                path.addLine(to: CGPoint(x: bounds.maxX, y: guide.position))
            }
        }
        layer.path = path
        layer.lineWidth = 1 / max(handleViewScale, 0.05)
    }

    private func makeGuideLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor.systemPink.cgColor
        layer.fillColor = nil
        layer.contentsScale = window?.backingScaleFactor ?? 2
        draftLayer.addSublayer(layer)
        guideLayer = layer
        return layer
    }
}
