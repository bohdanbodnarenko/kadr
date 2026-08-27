import AppKit
import os
import Shared

/// The selection overlay's content: a CALayer tree, driven directly by mouse events.
///
/// No SwiftUI anywhere in here, by rule (docs/04 §5). Dragging a selection has to track
/// the pointer at 120 Hz on a ProMotion display, and a SwiftUI body evaluation plus a
/// layout pass per mouse-moved event cannot hold that. Instead every event mutates layer
/// paths in place inside a `CATransaction` with actions disabled: no layout, no implicit
/// animation, no allocation per frame.
@MainActor
final class SelectionOverlayView: NSView {
    // MARK: Layers

    private let frozenLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let selectionBorderLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let badgeBackgroundLayer = CALayer()
    private let badgeTextLayer = CATextLayer()

    // MARK: State

    private(set) var interaction: SelectionInteraction
    private var sizeEntry = NumericSizeEntry()
    private let loupe: LoupeLayerGroup
    private let displayScale: DisplayScale
    private let logger = KadrLog.logger(.overlay)
    private var trackingArea: NSTrackingArea?
    private var isSpaceDown = false

    /// The selection was committed, in display-local points.
    var onCommit: ((CGRect) -> Void)?
    /// Esc, or a right-click.
    var onCancel: (() -> Void)?
    /// The pointer entered this display, so other overlays should hide their loupes.
    var onBecameActive: (() -> Void)?

    // MARK: Geometry constants

    private static let badgeHeight: CGFloat = 22

    init(frozenImage: CGImage, bounds: CGRect, scale: DisplayScale) {
        interaction = SelectionInteraction(bounds: CGRect(origin: .zero, size: bounds.size))
        loupe = LoupeLayerGroup(sampler: LoupeSampler(image: frozenImage, scale: scale), scale: scale)
        displayScale = scale
        super.init(frame: bounds)

        wantsLayer = true
        layer?.masksToBounds = true
        buildLayers(frozenImage: frozenImage)
        redraw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SelectionOverlayView is created in code only")
    }

    /// Top-left origin, so view coordinates match display space and the maths in
    /// `SelectionInteraction` needs no flipping (docs/04 §5).
    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    // MARK: - Layer tree

    private func buildLayers(frozenImage: CGImage) {
        guard let root = layer else { return }
        root.backgroundColor = .clear

        frozenLayer.frame = bounds
        frozenLayer.contents = frozenImage
        frozenLayer.contentsGravity = .resize
        // The frozen bitmap is already at native resolution; never let CA resample it.
        frozenLayer.magnificationFilter = .nearest
        frozenLayer.minificationFilter = .nearest
        root.addSublayer(frozenLayer)

        dimLayer.frame = bounds
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dimLayer.fillRule = .evenOdd
        root.addSublayer(dimLayer)

        crosshairLayer.frame = bounds
        crosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        crosshairLayer.lineWidth = 1 / displayScale.factor
        root.addSublayer(crosshairLayer)

        selectionBorderLayer.frame = bounds
        selectionBorderLayer.fillColor = nil
        selectionBorderLayer.strokeColor = NSColor.white.cgColor
        selectionBorderLayer.lineWidth = 1
        selectionBorderLayer.lineDashPattern = [4, 4]
        root.addSublayer(selectionBorderLayer)

        badgeBackgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        badgeBackgroundLayer.cornerRadius = 4
        badgeBackgroundLayer.isHidden = true
        root.addSublayer(badgeBackgroundLayer)

        badgeTextLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        badgeTextLayer.fontSize = 12
        badgeTextLayer.foregroundColor = NSColor.white.cgColor
        badgeTextLayer.alignmentMode = .center
        badgeTextLayer.contentsScale = displayScale.factor
        badgeTextLayer.isHidden = true
        root.addSublayer(badgeTextLayer)

        root.addSublayer(loupe.container)
        startMarchingAnts()
    }

    /// Marching ants, animated on the GPU rather than by a timer.
    ///
    /// Skipped when the user has asked for reduced motion (docs/03 §9).
    private func startMarchingAnts() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = 8
        animation.duration = 0.5
        animation.repeatCount = .infinity
        selectionBorderLayer.add(animation, forKey: "marchingAnts")
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        onBecameActive?()
    }

    override func mouseExited(with event: NSEvent) {
        loupe.hide()
        crosshairLayer.path = nil
    }

    override func mouseMoved(with event: NSEvent) {
        interaction.pointerMoved(to: convert(event.locationInWindow, from: nil))
        redraw()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sizeEntry.reset()
        interaction.begin(at: convert(event.locationInWindow, from: nil))
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        interaction.drag(to: convert(event.locationInWindow, from: nil), modifiers: modifiers(from: event))
        redraw()
    }

    override func mouseUp(with event: NSEvent) {
        interaction.drag(to: convert(event.locationInWindow, from: nil), modifiers: modifiers(from: event))
        interaction.end()
        redraw()

        if let rect = interaction.rect, interaction.phase == .selected {
            onCommit?(rect)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    private func modifiers(from event: NSEvent) -> SelectionModifiers {
        var modifiers: SelectionModifiers = []
        if event.modifierFlags.contains(.option) {
            modifiers.insert(.fromCenter)
        }
        if event.modifierFlags.contains(.shift) {
            modifiers.insert(.lockAspect)
        }
        return modifiers
    }

    // MARK: - Keyboard (docs/03 §1.1)

    /// Virtual key codes, named. `NSEvent` only offers the raw numbers.
    private enum KeyCode {
        static let escape: UInt16 = 53
        static let space: UInt16 = 49
        static let `return`: UInt16 = 36
        static let enter: UInt16 = 76
        static let delete: UInt16 = 51
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
        if handleTypedSize(event) {
            return
        }
        super.keyDown(with: event)
    }

    /// Esc, Space, Return and Delete, and the arrow keys.
    private func handleEditingKey(_ event: NSEvent) -> Bool {
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

    private func beginMovingIfNeeded() {
        guard !isSpaceDown else { return }
        isSpaceDown = true
        interaction.beginMovingSelection()
    }

    /// Backspace unwinds a typed size first, and only then clears the selection.
    private func handleDelete() {
        if !sizeEntry.deleteBackward() {
            interaction.cancelSelection()
        }
        redraw()
    }

    private func handleSelectAll(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers == "a" else { return false }
        interaction.selectAll()
        redraw()
        return true
    }

    /// Digits and separators typed anywhere on the overlay build up an exact size.
    private func handleTypedSize(_ event: NSEvent) -> Bool {
        var accepted = false
        for character in event.charactersIgnoringModifiers ?? "" where sizeEntry.accept(character) {
            accepted = true
        }
        guard accepted else { return false }
        redraw()
        return true
    }

    /// Arrows move the selection, ⌥-arrows resize it, ⇧ makes either coarse.
    private func handleArrow(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
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
        // Re-run the drag so ⌥ and ⇧ take effect without waiting for the next move.
        if interaction.phase == .dragging, let pointer = interaction.pointer {
            interaction.drag(to: pointer, modifiers: modifiers(from: event))
            redraw()
        }
    }

    private func commitTypedSizeOrSelection() {
        if let size = sizeEntry.size {
            interaction.setSize(size)
            sizeEntry.reset()
            redraw()
        }
        if let rect = interaction.rect, !rect.isEmpty {
            onCommit?(rect)
        }
    }

    // MARK: - Drawing

    /// Redraws everything that changed, with implicit animation off.
    ///
    /// One transaction per event, no layout pass, no view redraw: this is the hot path.
    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        updateDimming()
        updateCrosshair()
        updateBadge()
        updateLoupe()
    }

    private func updateDimming() {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let rect = interaction.rect, !rect.isEmpty {
            // Even-odd fill turns the second rect into a hole, so the selection shows
            // through at full brightness (docs/03 §1.1).
            path.addRect(rect)
            selectionBorderLayer.path = CGPath(rect: rect, transform: nil)
        } else {
            selectionBorderLayer.path = nil
        }
        dimLayer.path = path
    }

    private func updateCrosshair() {
        guard interaction.phase != .selected, let pointer = interaction.pointer else {
            crosshairLayer.path = nil
            return
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: pointer.x, y: bounds.minY))
        path.addLine(to: CGPoint(x: pointer.x, y: bounds.maxY))
        path.move(to: CGPoint(x: bounds.minX, y: pointer.y))
        path.addLine(to: CGPoint(x: bounds.maxX, y: pointer.y))
        crosshairLayer.path = path
    }

    private func updateBadge() {
        let text: String? = if !sizeEntry.isEmpty {
            sizeEntry.displayText
        } else if let rect = interaction.rect, !rect.isEmpty {
            DimensionFormatter.text(for: rect, scale: displayScale)
        } else {
            nil
        }

        guard let text, let rect = interaction.rect ?? interaction.pointer.map({
            CGRect(origin: $0, size: .zero)
        }) else {
            badgeTextLayer.isHidden = true
            badgeBackgroundLayer.isHidden = true
            return
        }

        badgeTextLayer.string = text
        let width = ceil(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        ).size().width) + 16

        // Below the selection by default, above it when there is no room.
        var origin = CGPoint(x: rect.midX - width / 2, y: rect.maxY + 8)
        if origin.y + Self.badgeHeight > bounds.maxY {
            origin.y = max(bounds.minY, rect.minY - Self.badgeHeight - 8)
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - width - 4)

        let frame = CGRect(origin: origin, size: CGSize(width: width, height: Self.badgeHeight))
        badgeBackgroundLayer.frame = frame
        badgeTextLayer.frame = frame.insetBy(dx: 0, dy: 3)
        badgeBackgroundLayer.isHidden = false
        badgeTextLayer.isHidden = false
    }

    private func updateLoupe() {
        guard interaction.phase != .selected, let pointer = interaction.pointer else {
            loupe.hide()
            return
        }
        loupe.update(pointer: pointer, within: bounds)
    }

    /// Hides the pointer-following chrome on displays the pointer is not on.
    func setActive(_ isActive: Bool) {
        guard !isActive else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loupe.hide()
        crosshairLayer.path = nil
        CATransaction.commit()
    }
}
