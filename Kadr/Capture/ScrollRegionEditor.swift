import AppKit
import OverlayKit
import QuartzCore
import Shared
import SwiftUI

/// The live, adjustable frame a scrolling capture starts from (docs/03 §1.6).
///
/// Scrolling capture used to freeze the screen and ask for a rectangle to be drawn. That
/// is the wrong tool: the page has to be scrolled into place before anything starts, and a
/// frozen screen cannot scroll. Now a frame appears over the live screen — around the
/// window under the pointer — with the rest dimmed. Its corners and edges resize it, the
/// bar above it moves it, and everything else passes straight through, so the
/// page inside can be scrolled and clicked while the frame is being set.
///
/// AppKit and Core Animation only in the pointer path (CLAUDE.md rule 4). The pass-through
/// is `InteractiveRegionTracker`'s: the panel takes events only over the frame's handles.
@MainActor
final class ScrollRegionEditor {
    private let screen: NSScreen
    private(set) var panel: ScrollRegionPanel?
    private var controls: NonActivatingPanel?
    private let keys = TransientHotKeys()

    var onStart: (DisplayRect) -> Void = { _ in }
    /// Start, and let Kadr do the scrolling.
    var onStartAuto: (DisplayRect) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init(screen: NSScreen) {
        self.screen = screen
    }

    private var displayID: CGDirectDisplayID? {
        ScreenDescriptor(screen)?.displayID
    }

    /// - Parameter window: the frame of the window under the pointer, in AppKit screen
    ///   coordinates, to start from.
    func present(aroundWindow window: ScreenRect?) {
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let local = window.map { $0.cgRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        let start = displayID.flatMap { ScrollRegionMemory.rect(forDisplay: $0, visible: visible) }
            ?? ScrollRegionGeometry.initialRect(window: local, visible: visible)

        let view = ScrollRegionView(frame: bounds, rect: start, limits: visible)
        view.onChange = { [weak self] rect in self?.frameChanged(rect) }
        view.onDragEnded = { [weak self] in self?.refreshPassThrough() }

        let panel = ScrollRegionPanel(contentRect: screen.frame, level: .floating)
        panel.contentView = view
        panel.acceptsMouseMovedEvents = true
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        InteractiveRegionTracker.shared.register(panel)

        showControls(for: start)
        // No activation: Kadr stays in the background so the page can be scrolled and
        // clicked, and Return and Escape still reach the frame (T-CAP-10).
        installKeys()
    }

    /// Stops editing: the frame stays, dimmed around, but nothing on it takes clicks.
    func lock() {
        removeControls()
        guard let panel else { return }
        InteractiveRegionTracker.shared.unregister(panel)
        panel.ignoresMouseEvents = true
        (panel.contentView as? ScrollRegionView)?.isLocked = true
    }

    func dismiss() {
        removeControls()
        guard let panel else { return }
        InteractiveRegionTracker.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }

    // MARK: - Frame

    private var currentRect: CGRect? {
        (panel?.contentView as? ScrollRegionView)?.rect
    }

    private func frameChanged(_ rect: CGRect) {
        if let displayID {
            ScrollRegionMemory.remember(rect, forDisplay: displayID)
        }
        placeControls(for: rect)
        updateControls(for: rect)
    }

    private func refreshPassThrough() {
        InteractiveRegionTracker.shared.update(at: NSEvent.mouseLocation)
    }

    private func start() {
        guard let rect = staged() else { return }
        onStart(rect)
    }

    private func startAuto() {
        guard let rect = staged() else { return }
        onStartAuto(rect)
    }

    /// Locks the frame and hands back the region it covers, in display space.
    private func staged() -> DisplayRect? {
        guard let rect = currentRect else { return nil }
        let global = ScreenRect(cgRect: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
        lock()
        return global.inDisplaySpace(.current)
    }

    private func cancel() {
        dismiss()
        onCancel()
    }

    // MARK: - Controls

    private func controlsView(for rect: CGRect) -> CaptureRegionStageView {
        let scale = screen.backingScaleFactor
        return CaptureRegionStageView(
            purpose: .scrolling,
            pixelSize: CGSize(width: rect.width * scale, height: rect.height * scale),
            start: { [weak self] in self?.start() },
            cancel: { [weak self] in self?.cancel() },
            startAuto: { [weak self] in self?.startAuto() }
        )
    }

    private func showControls(for rect: CGRect) {
        let hosting = NSHostingView(rootView: controlsView(for: rect))
        hosting.sizingOptions = .intrinsicContentSize
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let controls = NonActivatingPanel(contentRect: hosting.frame, level: .floating)
        controls.alwaysHiddenFromCaptures = true
        controls.contentView = hosting
        self.controls = controls
        placeControls(for: rect)
        controls.orderFrontRegardless()
        controls.makeKey()
    }

    private func updateControls(for rect: CGRect) {
        (controls?.contentView as? NSHostingView<CaptureRegionStageView>)?.rootView = controlsView(for: rect)
    }

    /// Below the frame when there is room, otherwise inside it along the bottom — never
    /// in the middle, where the content being lined up is.
    private func placeControls(for rect: CGRect) {
        guard let controls else { return }
        let size = controls.contentView?.fittingSize ?? controls.frame.size
        let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let visible = screen.visibleFrame
        let margin: CGFloat = 12
        let below = global.minY - margin - size.height
        let y = below >= visible.minY ? below : global.minY + margin
        let x = min(max(global.midX - size.width / 2, visible.minX + margin), visible.maxX - size.width - margin)
        controls.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func removeControls() {
        keys.stop()
        controls?.orderOut(nil)
        controls?.contentView = nil
        controls = nil
    }

    /// Return starts, ⌥Return starts with Kadr scrolling, Escape cancels.
    ///
    /// Hot keys rather than a local monitor: a local monitor only sees keys while Kadr is
    /// active, and the moment the user clicks into the page to line it up, it is not.
    private func installKeys() {
        keys.start(arrowBindings().merging([
            .returnKey: { [weak self] in self?.startIfEditing(auto: false) },
            .enter: { [weak self] in self?.startIfEditing(auto: false) },
            .optionReturn: { [weak self] in self?.startIfEditing(auto: true) },
            .escape: { [weak self] in
                guard self?.controls != nil else { return }
                self?.cancel()
            }
        ]) { _, new in new })
    }

    private func startIfEditing(auto: Bool) {
        guard controls != nil else { return }
        if auto {
            startAuto()
        } else {
            start()
        }
    }
}

/// The full-screen panel under the frame. It takes events only over the handles.
final class ScrollRegionPanel: NonActivatingPanel, InteractivelyMasked {
    var interactiveRegions: InteractiveRegions {
        guard let view = contentView as? ScrollRegionView, !view.isLocked else { return .none }
        // Mid-drag the whole screen is the handle, or the pointer outrunning the band
        // would drop the drag into the app underneath.
        if view.isDragging {
            return InteractiveRegions(rects: [frame])
        }
        let origin = frame.origin
        let rects = ScrollRegionGeometry.interactiveRects(for: view.rect, in: view.bounds)
        return InteractiveRegions(rects: rects.map { $0.offsetBy(dx: origin.x, dy: origin.y) })
    }

    var passesMouseThrough: Bool {
        get { ignoresMouseEvents }
        set {
            guard ignoresMouseEvents != newValue else { return }
            ignoresMouseEvents = newValue
        }
    }
}

/// Draws the dim, the frame, its handles and the move bar, and turns drags into a frame.
final class ScrollRegionView: NSView {
    private(set) var rect: CGRect
    let limits: CGRect
    var isLocked = false {
        didSet { layoutFrame() }
    }

    private(set) var isDragging = false
    var onChange: (CGRect) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let moveBar = CAShapeLayer()
    private let grabber = CAShapeLayer()
    private var handles: [CALayer] = []
    /// The press being dragged: what it grabbed, the frame then, and where it started.
    private struct Drag {
        let target: ScrollRegionGeometry.Target
        let start: CGRect
        let origin: CGPoint
    }

    private var drag: Drag?

    init(frame: CGRect, rect: CGRect, limits: CGRect) {
        self.rect = rect
        self.limits = limits
        super.init(frame: frame)
        wantsLayer = true
        configureLayers()
        layoutFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    private func configureLayers() {
        guard let root = layer else { return }
        let scale = window?.backingScaleFactor ?? ActiveScreen.resolve()?.backingScaleFactor ?? 2
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1.5
        border.shadowColor = NSColor.black.cgColor
        border.shadowOpacity = 0.4
        border.shadowRadius = 2
        border.shadowOffset = .zero
        moveBar.fillColor = NSColor.white.withAlphaComponent(0.92).cgColor
        moveBar.shadowColor = NSColor.black.cgColor
        moveBar.shadowOpacity = 0.35
        moveBar.shadowRadius = 3
        moveBar.shadowOffset = .zero
        // Three lines, the way every drag handle on the Mac is drawn.
        grabber.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        for layer in [dim, border, moveBar, grabber] {
            layer.contentsScale = scale
            root.addSublayer(layer)
        }
        // White dots, as the editor's crop handles are: the same gesture should not be
        // drawn two different ways in one app.
        handles = (0 ..< 8).map { _ in
            let handle = CALayer()
            handle.backgroundColor = NSColor.white.cgColor
            handle.cornerRadius = ScrollRegionGeometry.handleDiameter / 2
            handle.shadowColor = NSColor.black.cgColor
            handle.shadowOpacity = 0.35
            handle.shadowRadius = 2
            handle.shadowOffset = .zero
            handle.contentsScale = scale
            root.addSublayer(handle)
            return handle
        }
    }

    /// Moves every layer to the current frame, without implicit animation: a frame that
    /// lags the pointer by a quarter second feels broken.
    private func layoutFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(rect)
        dim.frame = bounds
        dim.path = path
        border.frame = bounds
        border.path = CGPath(rect: rect, transform: nil)
        let bar = ScrollRegionGeometry.moveBar(for: rect, in: bounds)
        moveBar.frame = bounds
        moveBar.path = CGPath(
            roundedRect: bar,
            cornerWidth: bar.height / 2,
            cornerHeight: bar.height / 2,
            transform: nil
        )
        grabber.frame = bounds
        grabber.path = Self.grabberPath(in: bar)
        let diameter = ScrollRegionGeometry.handleDiameter
        for (handle, centre) in zip(handles, ScrollRegionGeometry.handleCentres(for: rect)) {
            handle.frame = CGRect(
                x: centre.x - diameter / 2,
                y: centre.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            handle.isHidden = isLocked
        }
        moveBar.isHidden = isLocked
        grabber.isHidden = isLocked
        CATransaction.commit()
    }

    /// The three short lines in the middle of the move bar.
    private static func grabberPath(in bar: CGRect) -> CGPath {
        let path = CGMutablePath()
        let width: CGFloat = 22
        let thickness: CGFloat = 1.5
        let gap: CGFloat = 4
        let top = bar.midY + thickness / 2 + gap
        for index in 0 ..< 3 {
            let y = top - CGFloat(index) * (thickness + gap / 2)
            path.addRoundedRect(
                in: CGRect(x: bar.midX - width / 2, y: y, width: width, height: thickness),
                cornerWidth: thickness / 2,
                cornerHeight: thickness / 2
            )
        }
        return path
    }

    // MARK: - Pointer

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
        InteractiveRegionTracker.shared.update(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !isLocked, let target = ScrollRegionGeometry.target(at: point, in: rect, bounds: bounds) else {
            return
        }
        drag = Drag(target: target, start: rect, origin: point)
        isDragging = true
        if target == .move {
            NSCursor.closedHand.set()
        }
    }

    func setRect(_ newRect: CGRect) {
        rect = newRect
        layoutFrame()
        onChange(rect)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGVector(dx: point.x - drag.origin.x, dy: point.y - drag.origin.y)
        rect = ScrollRegionGeometry.dragged(drag.start, target: drag.target, by: delta, in: limits).integral
        layoutFrame()
        onChange(rect)
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        isDragging = false
        updateCursor(at: convert(event.locationInWindow, from: nil))
        onDragEnded()
    }

    private func updateCursor(at point: CGPoint) {
        guard !isLocked, let target = ScrollRegionGeometry.target(at: point, in: rect, bounds: bounds) else {
            NSCursor.arrow.set()
            return
        }
        Self.cursor(for: target).set()
    }

    private static func cursor(for target: ScrollRegionGeometry.Target) -> NSCursor {
        switch target {
        case .move:
            return .openHand
        case let .resize(horizontal, vertical):
            if #available(macOS 15, *) {
                return .frameResize(position: position(horizontal, vertical), directions: .all)
            }
            switch (horizontal, vertical) {
            case (_, nil): return .resizeLeftRight
            case (nil, _): return .resizeUpDown
            default: return .crosshair
            }
        }
    }

    @available(macOS 15, *)
    private static func position(
        _ horizontal: ScrollRegionGeometry.Horizontal?,
        _ vertical: ScrollRegionGeometry.Vertical?
    ) -> NSCursor.FrameResizePosition {
        switch (horizontal, vertical) {
        case (.left, .top): .topLeft
        case (.right, .top): .topRight
        case (.left, .bottom): .bottomLeft
        case (.right, .bottom): .bottomRight
        case (.left, nil): .left
        case (.right, nil): .right
        case (nil, .top): .top
        default: .bottom
        }
    }
}
