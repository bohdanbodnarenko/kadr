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

    let frozenLayer = CALayer()
    let dimLayer = CAShapeLayer()
    let selectionBorderLayer = CAShapeLayer()
    let crosshairLayer = CAShapeLayer()
    let badgeBackgroundLayer = CALayer()
    let badgeTextLayer = CATextLayer()
    /// Internal: the last-region ghost lives in `SelectionOverlayView+Ghost.swift`.
    let ghostLayer = CAShapeLayer()
    let ghostLabelLayer = CATextLayer()

    // MARK: State

    /// Which interaction the overlay is running (docs/03 §1.1, §1.2).
    enum Mode: Equatable {
        case area
        case window
    }

    private(set) var mode: Mode
    let purpose: SelectionPurpose
    var interaction: SelectionInteraction
    var windowPick = WindowPickInteraction()
    var sizeEntry = NumericSizeEntry()
    /// Internal, not private: the eyedropper half lives in
    /// `SelectionOverlayView+Eyedropper.swift`, and `private` is file-scoped.
    let loupe: LoupeLayerGroup
    let ruler: RulerLayerGroup
    let windowHighlight: WindowHighlightLayerGroup
    let handles = SelectionHandleLayerGroup()
    /// Internal: the last-region ghost lives in `SelectionOverlayView+Ghost.swift`.
    let displayScale: DisplayScale
    let hints: HintLayerGroup
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
    /// Last area on this display, drawn as a dashed ghost until the user starts dragging.
    var lastRegionGhost: CGRect?
    /// Teaching copy on the idle overlay (docs/03 §1.1). Off from Settings → Capture.
    var showsCaptureHints = true
    /// When true, mouse-up leaves handles until Enter commits (docs/03 §1.1, docs/14 UX-17C).
    var confirmsSelection = false
    /// `F` captures this display from area mode (docs/03 §1.3).
    var onCaptureDisplay: (() -> Void)?

    var activeHandle: SelectionHandleLayerGroup.Corner?
    var handleAnchor: CGPoint?
    /// Internal: keyboard extension toggles Command child-window picking (docs/03 §1.2).
    var isCommandDown = false
    var lastAccessibilityRect: CGRect?
    var accessibilityAnnouncedPhase = ""
    var accessibilityProxy: SelectionOverlayAccessibilityElement?

    // MARK: Geometry constants

    /// The badge's font, looked up once (docs/10 R1.4).
    ///
    /// `NSFont.monospacedDigitSystemFont` is not a cheap accessor — measured, the lookup is
    /// about 13µs of the 16µs this whole measurement used to cost, and it ran on every
    /// `mouseMoved` and `mouseDragged`. On a 120 Hz display that is two milliseconds of
    /// every second spent asking for a font that never changes.
    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    /// How wide the badge needs to be for some text.
    static func badgeWidth(for text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: badgeFont]).size().width) + 16
    }

    static let badgeHeight: CGFloat = 22

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
        hints = HintLayerGroup(scale: scale)
        displayScale = scale
        super.init(frame: bounds)

        wantsLayer = true
        layer?.masksToBounds = true
        buildLayers(frozenImage: frozenImage)
        installAccessibilityElement()
        refreshAccessibilityElement()
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

        addGhostLayers(to: root)

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
        root.addSublayer(hints.container)
        root.addSublayer(loupe.container)
        root.addSublayer(handles.container)
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
        if mode == .window {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if confirmsSelection, interaction.phase == .selected, let rect = interaction.rect {
            if let corner = handles.corner(at: point, in: rect, scale: displayScale) {
                activeHandle = corner
                handleAnchor = oppositePoint(for: corner, in: rect)
                return
            }
            if rect.contains(point) {
                sizeEntry.reset()
                interaction.begin(at: point)
                interaction.beginMovingSelection()
                redraw()
                return
            }
            commitCurrentSelection()
            return
        }

        sizeEntry.reset()
        interaction.begin(at: point)
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if mode == .area, let corner = activeHandle, let anchor = handleAnchor {
            interaction.setRect(resizedRect(from: corner, anchor: anchor, to: point))
            redraw()
            return
        }
        guard mode == .area else { return }
        interaction.drag(to: point, modifiers: modifiers(from: event))
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
        activeHandle = nil
        handleAnchor = nil
        redraw()

        guard let rect = interaction.rect, interaction.phase == .selected else { return }
        if confirmsSelection {
            refreshAccessibilityElement(announcePhaseChange: true)
            return
        }
        onCommit?(rect)
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
            updateHandles()
            updateGhost()
            updateCrosshair()
            updateRuler()
            updateBadge()
            updateLoupe()
            updateHints()
        case .window:
            updateWindowHighlight()
            hideGhost()
            updateHints()
        }
        refreshAccessibilityIfNeeded()
    }

    /// The windows this display can offer for picking (docs/03 §1.2).
    func setPickableWindows(_ windows: [PickableWindow]) {
        windowPick.setWindows(windows)
        redraw()
    }

    func setIncludesAuxiliaryWindows(_ includes: Bool) {
        guard windowPick.includesAuxiliaryWindows != includes else { return }
        windowPick.includesAuxiliaryWindows = includes
        if let pointer = interaction.pointer {
            windowPick.pointerMoved(to: pointer)
        }
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

extension String {
    /// Empty strings read as "nothing to show" rather than an empty badge.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
