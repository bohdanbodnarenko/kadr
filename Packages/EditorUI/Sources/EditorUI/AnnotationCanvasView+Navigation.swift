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

    override public func keyDown(with event: NSEvent) {
        if handleSpaceKeyDown(event) {
            return
        }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        handleEditingKey(event)
    }

    override public func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceIsDown = false
            endSpacePan()
            window?.invalidateCursorRects(for: self)
            return
        }
        super.keyUp(with: event)
    }

    private func handleSpaceKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false }
        if event.isARepeat {
            return true
        }
        guard !event.modifierFlags.contains(.command) else { return false }
        spaceIsDown = true
        window?.invalidateCursorRects(for: self)
        return true
    }

    private func handleEditingKey(_ event: NSEvent) {
        if applyArrowKey(event) || applyDeleteKey(event) || applyEscapeKey(event) {
            refreshAfterEdit()
            return
        }
        applyToolShortcut(event)
    }

    private func applyArrowKey(_ event: NSEvent) -> Bool {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: model.nudgeSelection(dx: -step, dy: 0)
        case 124: model.nudgeSelection(dx: step, dy: 0)
        case 125: model.nudgeSelection(dx: 0, dy: step)
        case 126: model.nudgeSelection(dx: 0, dy: -step)
        default: return false
        }
        return true
    }

    private func applyDeleteKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 51 || event.keyCode == 117 else { return false }
        model.deleteSelection()
        return true
    }

    private func applyEscapeKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        if model.tool != .select {
            model.selectTool(.select)
        } else {
            model.selection = []
        }
        return true
    }

    private func applyToolShortcut(_ event: NSEvent) {
        guard let character = event.charactersIgnoringModifiers?.lowercased().first,
              let tool = EditorTool.allCases.first(where: { $0.shortcut == character })
        else {
            super.keyDown(with: event)
            return
        }
        model.selectTool(tool)
        window?.invalidateCursorRects(for: self)
    }
}
