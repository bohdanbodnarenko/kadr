import AnnotationModel
import AppKit
import QuartzCore

/// Hover preview for the smart highlighter (docs/03 §3 P2).
public extension AnnotationCanvasView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        model.pointerMoved(
            to: imagePoint(fromWindowPoint: event.locationInWindow),
            modifiers: modifiers(from: event)
        )
        updateHighlightPreview()
    }

    /// A translucent book-style stroke over the word under the pointer.
    internal func updateHighlightPreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        highlightPreviewLayer?.removeFromSuperlayer()
        highlightPreviewLayer = nil

        guard model.draft == nil, let box = model.hoveredHighlightBox else { return }

        let path = CGMutablePath()
        path.move(to: CGPoint(x: box.minX, y: box.midY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.midY))
        let layer = CAShapeLayer()
        layer.path = path
        layer.strokeColor = NSColor.systemYellow.withAlphaComponent(0.55).cgColor
        layer.fillColor = nil
        layer.lineWidth = max(box.height * 1.15, 8)
        layer.lineCap = .round
        layer.compositingFilter = "multiplyBlendMode"
        draftLayer.addSublayer(layer)
        highlightPreviewLayer = layer
    }
}
