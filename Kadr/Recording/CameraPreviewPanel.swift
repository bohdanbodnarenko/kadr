import AppKit
import AVFoundation
import OverlayKit

/// A live view of the webcam, excluded from the recording it sits on.
///
/// Shown as soon as the camera is armed in the picker, so the exposure ramp finishes
/// before the file starts — and kept up during Area and Window selection, when the
/// control bar itself is hidden. Movable, resizable and optionally fullscreen, matching
/// CleanShot's presenter bubble.
@MainActor
final class CameraPreviewPanel {
    static let defaultDiameter: CGFloat = 160
    private static let margin: CGFloat = 24
    private static let minDiameter: CGFloat = 96
    private static let maxDiameter: CGFloat = 420

    /// Where the user last dragged it, so it comes back where they put it.
    static var savedOrigin: CGPoint?
    static var savedDiameter: CGFloat = CameraPreviewPanel.defaultDiameter
    static var isCircular = true
    static var fillsDisplay = false

    private var panel: NonActivatingPanel?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var chrome: CameraPreviewChromeView?

    var isShowing: Bool {
        panel != nil
    }

    /// Puts the bubble on screen, attached to an already-running capture session.
    func show(session: AVCaptureSession) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let frame = currentFrame()
        let panel = CameraPreviewBubblePanel(contentRect: frame, level: .floating)
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        CaptureExclusionRegistry.shared.register(panel)

        let chrome = CameraPreviewChromeView(frame: CGRect(origin: .zero, size: frame.size))
        chrome.wantsLayer = true
        chrome.layer?.masksToBounds = true
        chrome.layer?.backgroundColor = NSColor.black.cgColor
        chrome.onScroll = { [weak self] delta in self?.resize(by: delta) }
        chrome.onToggleFullscreen = { [weak self] in self?.toggleFullscreen() }
        chrome.onToggleCircular = { [weak self] in self?.toggleCircular() }
        chrome.setAccessibilityElement(true)
        chrome.setAccessibilityRole(.image)
        chrome.setAccessibilityLabel("Camera preview")
        chrome.setAccessibilityHelp("Scroll to resize. Double-click to fill the screen. Right-click for shape.")

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = chrome.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        chrome.layer?.addSublayer(preview)

        panel.contentView = chrome
        self.panel = panel
        self.previewLayer = preview
        self.chrome = chrome
        applyChrome()
        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel else { return }
        if !Self.fillsDisplay {
            Self.savedOrigin = panel.frame.origin
        }
        CaptureExclusionRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        previewLayer = nil
        chrome = nil
    }

    private func toggleFullscreen() {
        if !Self.fillsDisplay, let panel {
            Self.savedOrigin = panel.frame.origin
        }
        Self.fillsDisplay.toggle()
        guard let panel else { return }
        panel.setFrame(currentFrame(), display: true)
        applyChrome()
    }

    private func toggleCircular() {
        Self.isCircular.toggle()
        applyChrome()
    }

    private func resize(by delta: CGFloat) {
        guard !Self.fillsDisplay else { return }
        Self.savedDiameter = min(
            max(Self.savedDiameter + delta, Self.minDiameter),
            Self.maxDiameter
        )
        guard let panel else { return }
        var frame = currentFrame()
        if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            Self.savedOrigin = frame.origin
        }
        panel.setFrame(frame, display: true)
        chrome?.frame = CGRect(origin: .zero, size: frame.size)
        applyChrome()
    }

    private func applyChrome() {
        let diameter = Self.fillsDisplay
            ? min(panel?.frame.width ?? Self.savedDiameter, panel?.frame.height ?? Self.savedDiameter)
            : Self.savedDiameter
        let radius = Self.isCircular && !Self.fillsDisplay ? diameter / 2 : (Self.fillsDisplay ? 0 : 18)
        chrome?.layer?.cornerRadius = radius
        chrome?.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        chrome?.layer?.borderWidth = Self.fillsDisplay ? 0 : 1
        previewLayer?.frame = chrome?.bounds ?? .zero
        panel?.hasShadow = !Self.fillsDisplay
        panel?.isMovable = !Self.fillsDisplay
    }

    private func currentFrame() -> CGRect {
        if Self.fillsDisplay {
            return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        }
        let diameter = Self.savedDiameter
        return CGRect(origin: origin(for: diameter), size: CGSize(width: diameter, height: diameter))
    }

    private func origin(for diameter: CGFloat) -> CGPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let fallback = CGPoint(
            x: visible.maxX - diameter - Self.margin,
            y: visible.minY + Self.margin
        )
        let proposed = Self.savedOrigin ?? fallback
        return CGPoint(
            x: min(max(proposed.x, visible.minX), max(visible.minX, visible.maxX - diameter)),
            y: min(max(proposed.y, visible.minY), max(visible.minY, visible.maxY - diameter))
        )
    }
}

@MainActor
private final class CameraPreviewChromeView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    var onToggleFullscreen: (() -> Void)?
    var onToggleCircular: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 12
        onScroll?(delta)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onToggleFullscreen?()
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Circle", action: #selector(makeCircle), keyEquivalent: "")
        menu.addItem(withTitle: "Rounded", action: #selector(makeRounded), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: CameraPreviewPanel.fillsDisplay ? "Exit Full Screen" : "Fill Screen",
            action: #selector(toggleFill),
            keyEquivalent: ""
        )
        for item in menu.items {
            item.target = self
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc
    private func makeCircle() {
        if !CameraPreviewPanel.isCircular {
            onToggleCircular?()
        }
    }

    @objc
    private func makeRounded() {
        if CameraPreviewPanel.isCircular {
            onToggleCircular?()
        }
    }

    @objc
    private func toggleFill() {
        onToggleFullscreen?()
    }
}

/// A bubble that must never take the keyboard away from the app being recorded.
private final class CameraPreviewBubblePanel: NonActivatingPanel {
    override var canBecomeKey: Bool {
        false
    }
}
