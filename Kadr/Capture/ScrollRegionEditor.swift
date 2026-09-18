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
/// grip on its top edge moves it, and everything else passes straight through, so the
/// page inside can be scrolled and clicked while the frame is being set.
///
/// AppKit and Core Animation only in the pointer path (CLAUDE.md rule 4). The pass-through
/// is `InteractiveRegionTracker`'s: the panel takes events only over the frame's handles.
@MainActor
final class ScrollRegionEditor {
    private let screen: NSScreen
    private var panel: ScrollRegionPanel?
    private var controls: NonActivatingPanel?
    private var keyMonitor: Any?

    var onStart: (DisplayRect) -> Void = { _ in }
    var onCancel: () -> Void = {}

    /// The last frame on each display this session, so a second capture starts there.
    private static var remembered: [CGDirectDisplayID: CGRect] = [:]

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
        let start = displayID.flatMap { Self.remembered[$0] }
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
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
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
            Self.remembered[displayID] = rect
        }
        placeControls(for: rect)
        updateControls(for: rect)
    }

    private func refreshPassThrough() {
        InteractiveRegionTracker.shared.update(at: NSEvent.mouseLocation)
    }

    private func start() {
        guard let rect = currentRect else { return }
        let global = ScreenRect(cgRect: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
        lock()
        onStart(global.inDisplaySpace(.current))
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
            cancel: { [weak self] in self?.cancel() }
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
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        controls?.orderOut(nil)
        controls?.contentView = nil
        controls = nil
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, controls != nil else { return event }
            switch event.keyCode {
            case 36, 76:
                start()
                return nil
            case 53:
                cancel()
                return nil
            default:
                return event
            }
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
        return InteractiveRegions(rects: ScrollRegionGeometry.interactiveRects(for: view.rect).map {
            $0.offsetBy(dx: origin.x, dy: origin.y)
        })
    }

    var passesMouseThrough: Bool {
        get { ignoresMouseEvents }
        set {
            guard ignoresMouseEvents != newValue else { return }
            ignoresMouseEvents = newValue
        }
    }
}

/// Draws the dim, the frame, its handles and the grip, and turns drags into a new frame.
final class ScrollRegionView: NSView {
    private(set) var rect: CGRect
    private let limits: CGRect
    var isLocked = false {
        didSet { layoutFrame() }
    }

    private(set) var isDragging = false
    var onChange: (CGRect) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let grip = CAShapeLayer()
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
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1.5
        border.shadowColor = NSColor.black.cgColor
        border.shadowOpacity = 0.4
        border.shadowRadius = 2
        border.shadowOffset = .zero
        grip.fillColor = NSColor.white.cgColor
        grip.shadowColor = NSColor.black.cgColor
        grip.shadowOpacity = 0.35
        grip.shadowRadius = 2
        grip.shadowOffset = .zero
        for layer in [dim, border, grip] {
            layer.contentsScale = scale
            root.addSublayer(layer)
        }
        handles = (0 ..< 8).map { _ in
            let handle = CALayer()
            handle.backgroundColor = NSColor.white.cgColor
            handle.borderColor = NSColor.controlAccentColor.cgColor
            handle.borderWidth = 1.5
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
        let gripRect = ScrollRegionGeometry.grip(for: rect)
        grip.frame = bounds
        grip.path = CGPath(
            roundedRect: gripRect.insetBy(dx: 12, dy: 5),
            cornerWidth: 3,
            cornerHeight: 3,
            transform: nil
        )
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
        grip.isHidden = isLocked
        CATransaction.commit()
    }

    // MARK: - Pointer

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
        InteractiveRegionTracker.shared.update(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !isLocked, let target = ScrollRegionGeometry.target(at: point, in: rect) else { return }
        drag = Drag(target: target, start: rect, origin: point)
        isDragging = true
        if target == .move {
            NSCursor.closedHand.set()
        }
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
        guard !isLocked, let target = ScrollRegionGeometry.target(at: point, in: rect) else {
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
