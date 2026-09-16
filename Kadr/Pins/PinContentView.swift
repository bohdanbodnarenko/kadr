import AppKit

/// The pin's content view, which turns AppKit events into panel commands.
@MainActor
final class PinContentView: NSView {
    weak var panel: PinPanel?

    override var acceptsFirstResponder: Bool {
        true
    }

    /// The end of a corner drag: now the sharp texture is worth fetching (docs/07 M9).
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        panel?.reloadBackingImageIfNeeded()
        panel?.onGeometryChanged?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        panel?.setHoverBarVisible(true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        panel?.setHoverBarVisible(false)
        super.mouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        panel?.handleScroll(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            panel?.resetZoom()
        } else if event.modifierFlags.contains(.option) {
            // ⌥-drag hands the file to another app; a plain drag still moves the pin,
            // which is the gesture people already know (docs/03 §6, docs/09 U0.1).
            panel?.beginFileDrag(from: self, event: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            panel?.closeFromMiddleClick()
            return
        }
        super.otherMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: panel?.nudge(dx: -step, dy: 0)
        case 124: panel?.nudge(dx: step, dy: 0)
        case 125: panel?.nudge(dx: 0, dy: -step)
        case 126: panel?.nudge(dx: 0, dy: step)
        case 53: panel?.onClose?()
        default: super.keyDown(with: event)
        }
    }
}
