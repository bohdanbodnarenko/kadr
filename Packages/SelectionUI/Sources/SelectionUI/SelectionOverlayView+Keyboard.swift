import AppKit
import Shared

/// Keyboard handling for the selection overlay (docs/03 §1.1, §1.2).
///
/// Split from the view itself because it is a large, flat dispatch table and the drawing
/// code is easier to follow without it in the way.
extension SelectionOverlayView {
    /// Virtual key codes, named. `NSEvent` only offers the raw numbers.
    enum KeyCode {
        static let escape: UInt16 = 53
        static let space: UInt16 = 49
        static let `return`: UInt16 = 36
        static let enter: UInt16 = 76
        static let delete: UInt16 = 51
        static let tab: UInt16 = 48
        static let arrowLeft: UInt16 = 123
        static let arrowRight: UInt16 = 124
        static let arrowDown: UInt16 = 125
        static let arrowUp: UInt16 = 126
    }

    override func keyDown(with event: NSEvent) {
        if handleEditingKey(event) {
            return
        }
        if handleSelectAll(event) {
            return
        }
        if handleModeKey(event) {
            return
        }
        if handlePrecisionKey(event) {
            return
        }
        if handleColorKey(event) {
            return
        }
        if mode == .window, handleWindowModeKey(event) {
            return
        }
        if handleTypedSize(event) {
            return
        }
        super.keyDown(with: event)
    }

    /// `C` toggles full-screen guides and coordinates (docs/03 §7).
    func handlePrecisionKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "c"
        else { return false }
        isPrecisionMode.toggle()
        onPrecisionModeChanged?(isPrecisionMode)
        redraw()
        return true
    }

    /// `E` picks colours, `F` changes the notation, `X` stores one to compare against
    /// (docs/03 §3 P3, docs/06 M22).
    func handleColorKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command), mode == .area else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "e":
            setEyedropperMode(!isEyedropperMode)
            onEyedropperModeChanged?(isEyedropperMode)
        case "f" where isEyedropperMode:
            colorFormat = colorFormat.next
            redraw()
        case "x" where isEyedropperMode:
            sampleComparisonColor()
        default:
            return false
        }
        return true
    }

    /// W and A switch between picking a window and dragging a region (docs/03 §1.2).
    func handleModeKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        // Not while picking a colour: a window is not a colour, and W used to leave the
        // eyedropper for a window screenshot that overwrote the clipboard (T-CAP-8).
        case "w" where mode == .area && !isEyedropperMode:
            setMode(.window)
            onModeChanged?(.window)
        case "a" where mode == .window:
            setMode(.area)
            onModeChanged?(.area)
        case "f" where mode == .area && !isEyedropperMode && purpose == .capture:
            onCaptureDisplay?()
        default:
            return false
        }
        return true
    }

    /// ⇥ cycles windows, Return picks the highlighted one.
    func handleWindowModeKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.tab:
            windowPick.cycle(reverse: event.modifierFlags.contains(.shift))
            redraw()
        case KeyCode.return, KeyCode.enter:
            guard let window = windowPick.hovered else { return true }
            onCommitWindow?(window, event.modifierFlags.contains(.option))
        default:
            return false
        }
        return true
    }

    /// Esc, Space, Return and Delete, and the arrow keys.
    func handleEditingKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.escape:
            onCancel?()
        case KeyCode.space:
            beginMovingIfNeeded()
        case KeyCode.return, KeyCode.enter:
            commitTypedSizeOrSelection()
        case KeyCode.delete:
            handleDelete()
        case KeyCode.arrowLeft, KeyCode.arrowRight, KeyCode.arrowDown, KeyCode.arrowUp:
            handleArrow(keyCode: event.keyCode, modifiers: event.modifierFlags)
        default:
            return false
        }
        return true
    }

    func beginMovingIfNeeded() {
        guard !isSpaceDown else { return }
        isSpaceDown = true
        interaction.beginMovingSelection()
    }

    /// Backspace unwinds a typed size first, and only then clears the selection.
    func handleDelete() {
        if !sizeEntry.deleteBackward() {
            interaction.cancelSelection()
        }
        redraw()
    }

    func handleSelectAll(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers == "a" else { return false }
        interaction.selectAll()
        redraw()
        return true
    }

    /// Digits and separators typed anywhere on the overlay build up an exact size.
    func handleTypedSize(_ event: NSEvent) -> Bool {
        var accepted = false
        for character in event.charactersIgnoringModifiers ?? "" where sizeEntry.accept(character) {
            accepted = true
        }
        guard accepted else { return false }
        redraw()
        return true
    }

    /// Arrows move the selection, ⌥-arrows resize it, ⇧ makes either coarse.
    func handleArrow(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let direction: NudgeDirection = switch keyCode {
        case KeyCode.arrowLeft: .left
        case KeyCode.arrowRight: .right
        case KeyCode.arrowDown: .down
        default: .up
        }
        let coarse = modifiers.contains(.shift)
        if modifiers.contains(.option) {
            interaction.resize(direction, coarse: coarse)
        } else {
            interaction.nudge(direction, coarse: coarse)
        }
        redraw()
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == KeyCode.space {
            isSpaceDown = false
            interaction.endMovingSelection()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let commandDown = event.modifierFlags.contains(.command)
        if mode == .window, commandDown != isCommandDown {
            isCommandDown = commandDown
            setIncludesAuxiliaryWindows(commandDown)
        }
        // Re-run the drag so ⌥ and ⇧ take effect without waiting for the next move.
        if interaction.phase == .dragging, let pointer = interaction.pointer {
            interaction.drag(to: pointer, modifiers: modifiers(from: event))
            redraw()
        }
    }

    func commitTypedSizeOrSelection() {
        // In eyedropper mode Return means "take this colour", not "take this rectangle".
        if isEyedropperMode {
            if let pick = currentPick {
                onPickColor?(pick)
            }
            return
        }
        if let size = sizeEntry.size {
            interaction.setSize(size)
            sizeEntry.reset()
            redraw()
        }
        guard let rect = interaction.rect, !rect.isEmpty else { return }
        if confirmsSelection, interaction.phase != .selected {
            interaction.setRect(rect)
            redraw()
            refreshAccessibilityElement(announcePhaseChange: true)
            return
        }
        onCommit?(rect)
    }
}
