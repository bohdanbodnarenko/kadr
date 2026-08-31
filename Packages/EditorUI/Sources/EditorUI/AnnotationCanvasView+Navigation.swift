import AppKit

extension AnnotationCanvasView {
    func beginSpacePan(with event: NSEvent) {
        spacePanAnchor = event.locationInWindow
        spacePanClipOrigin = enclosingScrollView?.contentView.bounds.origin
        NSCursor.closedHand.set()
    }

    func continueSpacePan(with event: NSEvent) -> Bool {
        guard let anchor = spacePanAnchor,
              let origin = spacePanClipOrigin,
              let scrollView = enclosingScrollView
        else {
            return false
        }
        let magnification = max(scrollView.magnification, 0.001)
        let dx = (event.locationInWindow.x - anchor.x) / magnification
        let dy = (event.locationInWindow.y - anchor.y) / magnification
        // The canvas is flipped, so a downward mouse move increases the clip origin.
        scrollView.contentView.scroll(to: CGPoint(x: origin.x - dx, y: origin.y + dy))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    @discardableResult
    func endSpacePan() -> Bool {
        guard spacePanAnchor != nil else { return false }
        spacePanAnchor = nil
        spacePanClipOrigin = nil
        window?.invalidateCursorRects(for: self)
        return true
    }
}
