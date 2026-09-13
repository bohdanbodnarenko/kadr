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

    /// Which interaction the overlay is running (docs/03 §1.1, §1.2).
    enum Mode: Equatable {
        case area
        case window
    }

    private(set) var mode: Mode
    private let purpose: SelectionPurpose
    var interaction: SelectionInteraction
    var windowPick = WindowPickInteraction()
    var sizeEntry = NumericSizeEntry()
    /// Internal, not private: the eyedropper half lives in
    /// `SelectionOverlayView+Eyedropper.swift`, and `private` is file-scoped.
    let loupe: LoupeLayerGroup
    private let ruler: RulerLayerGroup
    private let windowHighlight: WindowHighlightLayerGroup
    private let displayScale: DisplayScale
    private let logger = KadrLog.logger(.overlay)
    private var trackingArea: NSTrackingArea?
    var isSpaceDown = false

    /// The selection was committed, in display-local points.
    var onCommit: ((CGRect) -> Void)?
    /// Esc, or a right-click.
    var onCancel: (() -> Void)?
    /// The pointer entered this display, so other overlays should hide their loupes.
    var onBecameActive: (() -> Void)?
    /// A window was picked. `togglesShadow` reports ⌥ held at click (docs/03 §1.2).
    var onCommitWindow: ((PickableWindow, _ togglesShadow: Bool) -> Void)?
    /// The user switched modes, so every other display's overlay should follow.
    var onModeChanged: ((Mode) -> Void)?
    /// Precision crosshair was toggled with `C` (docs/03 §7).
    var onPrecisionModeChanged: ((Bool) -> Void)?
    var isPrecisionMode = false

    // MARK: Eyedropper (docs/03 §3 P3, docs/06 M22)

    /// `E` turns the loupe into a colour picker.
    ///
    /// The loupe already reads pixels out of the frozen image, which is what makes this
    /// nearly free — and what makes it *correct*: the colour reported is the colour in the
    /// file, not a re-sample of a screen that has since changed (docs/04 §4.2).
    var isEyedropperMode = false
    /// Which notation the readout uses. `F` cycles it.
    var colorFormat: ColorFormat = .hex
    /// The second sample, for the contrast readout. `X` takes it.
    var comparisonColor: SampledColor?
    /// Return in eyedropper mode reports the pick instead of committing a selection.
    var onPickColor: ((ColorPick) -> Void)?
    /// The eyedropper was toggled, so every other display's overlay can follow.
    var onEyedropperModeChanged: ((Bool) -> Void)?

    // MARK: Geometry constants

    /// The badge's font, looked up once (docs/10 R1.4).
    ///
    /// `NSFont.monospacedDigitSystemFont` is not a cheap accessor — measured, the lookup is
    /// about 13µs of the 16µs this whole measurement used to cost, and it ran on every
    /// `mouseMoved` and `mouseDragged`. On a 120 Hz display that is two milliseconds of
    /// every second spent asking for a font that never changes.
    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    /// How wide the badge needs to be for some text.
    private static func badgeWidth(for text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: badgeFont]).size().width) + 16
    }

    private static let badgeHeight: CGFloat = 22

    init(
        frozenImage: CGImage,
        bounds: CGRect,
        scale: DisplayScale,
        mode: Mode = .area,
        purpose: SelectionPurpose = .capture
    ) {
        self.mode = mode
        self.purpose = purpose
        interaction = SelectionInteraction(bounds: CGRect(origin: .zero, size: bounds.size))
        windowHighlight = WindowHighlightLayerGroup(scale: scale)
        loupe = LoupeLayerGroup(sampler: LoupeSampler(image: frozenImage, scale: scale), scale: scale)
        ruler = RulerLayerGroup(scale: scale)
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
        // Capture Text tints the dimming, so the user can see which hotkey they hit
        // before they start dragging (docs/03 §1.7).
        dimLayer.fillColor = switch purpose {
        case .capture: NSColor.black.withAlphaComponent(0.45).cgColor
        case .recognizeText: NSColor.systemIndigo.withAlphaComponent(0.35).cgColor
        case .scrollingCapture: NSColor.systemTeal.withAlphaComponent(0.35).cgColor
        case .inspect: NSColor.systemOrange.withAlphaComponent(0.32).cgColor
        }
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

        root.addSublayer(ruler.container)
        root.addSublayer(windowHighlight.container)
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
        let point = convert(event.locationInWindow, from: nil)
        interaction.pointerMoved(to: point)

        if mode == .window {
            // Only redraw when the highlighted window actually changed; most moves stay
            // inside the same window and need no work at all.
            if windowPick.pointerMoved(to: point) {
                redraw()
            }
            return
        }
        redraw()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard mode == .area else { return }
        sizeEntry.reset()
        interaction.begin(at: convert(event.locationInWindow, from: nil))
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        interaction.drag(to: convert(event.locationInWindow, from: nil), modifiers: modifiers(from: event))
        redraw()
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .window {
            guard let window = windowPick.hovered else { return }
            // ⌥ at click inverts the shadow setting for this capture (docs/03 §1.2).
            onCommitWindow?(window, event.modifierFlags.contains(.option))
            return
        }

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

    func modifiers(from event: NSEvent) -> SelectionModifiers {
        var modifiers: SelectionModifiers = []
        if event.modifierFlags.contains(.option) {
            modifiers.insert(.fromCenter)
        }
        if event.modifierFlags.contains(.shift) {
            modifiers.insert(.lockAspect)
        }
        if event.modifierFlags.contains(.command) {
            modifiers.insert(.freeform)
        }
        return modifiers
    }

    // MARK: - Drawing

    /// Redraws everything that changed, with implicit animation off.
    ///
    /// Internal rather than private: the keyboard extension lives in a sibling file.
    ///
    /// One transaction per event, no layout pass, no view redraw: this is the hot path.
    func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch mode {
        case .area:
            windowHighlight.hide()
            updateDimming()
            updateCrosshair()
            updateRuler()
            updateBadge()
            updateLoupe()
        case .window:
            updateWindowHighlight()
        }
    }

    /// Window mode dims everything and lifts the hovered window out of it.
    private func updateWindowHighlight() {
        crosshairLayer.path = nil
        selectionBorderLayer.path = nil
        badgeBackgroundLayer.isHidden = true
        badgeTextLayer.isHidden = true
        loupe.hide()
        ruler.hide()

        let path = CGMutablePath()
        path.addRect(bounds)
        if let window = windowPick.hovered {
            let frame = window.frame.intersection(bounds)
            if !frame.isEmpty {
                path.addRoundedRect(in: frame, cornerWidth: 6, cornerHeight: 6)
            }
            windowHighlight.show(window, within: bounds)
        } else {
            windowHighlight.hide()
        }
        dimLayer.path = path
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
        guard isPrecisionMode, interaction.phase != .selected, let pointer = interaction.pointer else {
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

    /// The pixel ruler, which rides along with precision mode (docs/06 M21).
    private func updateRuler() {
        guard isPrecisionMode, let rect = interaction.rect, !rect.isEmpty else {
            ruler.hide()
            return
        }
        ruler.show(along: rect)
    }

    private func updateBadge() {
        let measurement: String? = if !sizeEntry.isEmpty {
            sizeEntry.displayText
        } else if let rect = interaction.rect, !rect.isEmpty {
            DimensionFormatter.text(for: rect, scale: displayScale)
        } else if isPrecisionMode, let pointer = interaction.pointer {
            String(format: "%.0f, %.0f", pointer.x, pointer.y)
        } else {
            nil
        }
        // The badge names the mode as well as the size, so Capture Text is unmistakable.
        // The eyedropper says so too, and lists its own keys — nobody guesses `F` and `X`.
        let modeBadge = isEyedropperMode ? "COLOUR  F: format  X: compare" : purpose.badge
        let text = [modeBadge, isEyedropperMode ? nil : measurement].compactMap(\.self)
            .joined(separator: "  ")
            .nilIfEmpty

        guard let text, let rect = interaction.rect ?? interaction.pointer.map({
            CGRect(origin: $0, size: .zero)
        }) else {
            badgeTextLayer.isHidden = true
            badgeBackgroundLayer.isHidden = true
            return
        }

        // Set only when it changed. Assigning `string` re-rasterises the layer, and a drag
        // along one axis leaves the text identical for most of its length.
        if badgeTextLayer.string as? String != text {
            badgeTextLayer.string = text
        }
        let width = Self.badgeWidth(for: text)

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
        loupe.update(pointer: pointer, within: bounds, readout: eyedropperReadout)
    }

    /// The windows this display can offer for picking (docs/03 §1.2).
    func setPickableWindows(_ windows: [PickableWindow]) {
        windowPick.setWindows(windows)
        redraw()
    }

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        interaction.cancelSelection()
        windowPick.clearHover()
        if mode == .window, let pointer = interaction.pointer {
            windowPick.pointerMoved(to: pointer)
        }
        redraw()
    }

    /// Hands the view the edges the selection should stick to (docs/06 M21).
    func setSnapping(_ snapping: SelectionSnapping?) {
        interaction.snapping = snapping
    }

    func setPrecisionMode(_ enabled: Bool) {
        guard enabled != isPrecisionMode else { return }
        isPrecisionMode = enabled
        redraw()
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

private extension String {
    /// Empty strings read as "nothing to show" rather than an empty badge.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
