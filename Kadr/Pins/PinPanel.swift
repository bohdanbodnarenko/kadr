import AppKit
import HistoryKit
import os
import OverlayKit
import Shared

/// A pinned screenshot: a borderless, always-on-top reference window (docs/03 §4).
///
/// The memory rule is the interesting part. A pin shows a *downsampled* texture sized to
/// the panel, not the capture — 20 pins of 5K screenshots at full resolution would be
/// well over a gigabyte, and the spec's budget is 40 MB for all of them. Full resolution
/// is reloaded only when it is actually needed: zoomed past 1:1, or copied.
@MainActor
final class PinPanel: NonActivatingPanel {
    private let imageView = NSImageView()
    private let loader = ThumbnailLoader()
    private let logger = KadrLog.logger(.overlay)

    /// Where the capture lives; the pin holds a URL, not a bitmap.
    let fileURL: URL
    /// The capture's real pixel size, read from metadata rather than by decoding.
    let pixelSize: PixelSize

    private var zoom: CGFloat = 1
    private var isClickThrough = false
    private var clickThroughBadge: NSView?

    /// Fired for the menu commands the pin does not implement itself.
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    init?(fileURL: URL, scale: CGFloat) {
        guard let pixelSize = ThumbnailLoader().pixelSize(for: fileURL) else { return nil }
        self.fileURL = fileURL
        self.pixelSize = pixelSize

        // Shown at captured size: pixels divided by the display scale gives points.
        let width = CGFloat(pixelSize.width) / scale
        let height = CGFloat(pixelSize.height) / scale

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        configureAsOverlay(level: .floating)
        // Pins are reference layers the user arranges by hand.
        isMovableByWindowBackground = true
        // On every Space, because a reference you have to chase between Spaces is useless.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        imageView.autoresizingMask = [.width, .height]

        let container = PinContentView(frame: imageView.frame)
        container.panel = self
        container.addSubview(imageView)
        contentView = container

        reloadBackingImage()
    }

    /// A pin never takes focus when it appears (docs/03 §4 accept list).
    override var canBecomeKey: Bool {
        !isClickThrough
    }

    func present(at origin: CGPoint) {
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    func dismiss() {
        contentView = nil
        imageView.image = nil
        orderOut(nil)
        close()
    }

    // MARK: - Backing image

    /// Loads a texture sized for the panel, not the capture (docs/03 §4).
    ///
    /// Reloaded whenever the panel resizes so a pin scaled up stays sharp, and dropped
    /// back down when it shrinks so the memory goes with it.
    func reloadBackingImage() {
        let scale = screen?.backingScaleFactor ?? 2
        let longestEdge = max(frame.width, frame.height) * scale * max(1, zoom)
        // Never ask for more pixels than the capture actually has.
        let target = min(Int(longestEdge.rounded()), max(pixelSize.width, pixelSize.height))

        guard let image = loader.thumbnail(for: fileURL, maxPixelSize: target) else {
            logger.error("Could not load a backing image for \(self.fileURL.lastPathComponent, privacy: .public)")
            return
        }
        imageView.image = NSImage(cgImage: image, size: frame.size)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let changed = frameRect.size != frame.size
        super.setFrame(frameRect, display: flag)
        if changed {
            reloadBackingImage()
        }
    }

    // MARK: - Zoom and opacity (docs/03 §4)

    /// ⌥-scroll zooms; plain scroll adjusts opacity between 20% and 100%.
    func handleScroll(_ event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            setZoom(zoom * (1 + event.scrollingDeltaY / 200))
        } else {
            alphaValue = min(max(alphaValue + event.scrollingDeltaY / 200, 0.2), 1)
        }
    }

    /// Double-click returns the pin to 100% (docs/03 §4).
    func resetZoom() {
        setZoom(1)
    }

    private func setZoom(_ newZoom: CGFloat) {
        zoom = min(max(newZoom, 0.1), 8)
        let scale = screen?.backingScaleFactor ?? 2
        let width = CGFloat(pixelSize.width) / scale * zoom
        let height = CGFloat(pixelSize.height) / scale * zoom
        setFrame(
            CGRect(origin: frame.origin, size: CGSize(width: width, height: height)),
            display: true
        )
    }

    /// Arrow keys nudge the pin, ⇧ by ten points (docs/03 §4).
    func nudge(dx: CGFloat, dy: CGFloat) {
        setFrameOrigin(CGPoint(x: frame.origin.x + dx, y: frame.origin.y + dy))
    }

    // MARK: - Click-through (docs/03 §4)

    /// ⌘⌥L turns the pin into a pure reference layer that clicks pass through.
    ///
    /// A window that swallows nothing and shows no sign of it is a trap, so entering the
    /// mode leaves a small visible badge — the affordance for getting back out.
    func toggleClickThrough() {
        isClickThrough.toggle()
        ignoresMouseEvents = isClickThrough
        if isClickThrough {
            showClickThroughBadge()
        } else {
            clickThroughBadge?.removeFromSuperview()
            clickThroughBadge = nil
        }
        logger.info("Pin click-through \(self.isClickThrough ? "on" : "off", privacy: .public)")
    }

    var clickThroughEnabled: Bool {
        isClickThrough
    }

    private func showClickThroughBadge() {
        let badge = NSTextField(labelWithString: "⌘⌥L to interact")
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badge.textColor = .white
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        badge.drawsBackground = true
        badge.alignment = .center
        badge.sizeToFit()
        badge.frame = CGRect(
            x: 6,
            y: 6,
            width: badge.frame.width + 12,
            height: badge.frame.height + 6
        )
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        contentView?.addSubview(badge)
        clickThroughBadge = badge
    }
}

/// The pin's content view, which turns AppKit events into panel commands.
@MainActor
private final class PinContentView: NSView {
    weak var panel: PinPanel?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        panel?.handleScroll(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            panel?.resetZoom()
        } else {
            super.mouseDown(with: event)
        }
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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let panel else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let copy = NSMenuItem(title: "Copy", action: #selector(copyPin), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        let save = NSMenuItem(title: "Save…", action: #selector(savePin), keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        // M7b brings the editor and M8 brings OCR.
        let annotate = NSMenuItem(title: "Annotate", action: nil, keyEquivalent: "")
        annotate.isEnabled = false
        menu.addItem(annotate)

        let ocr = NSMenuItem(title: "Copy Text", action: nil, keyEquivalent: "")
        ocr.isEnabled = false
        menu.addItem(ocr)

        menu.addItem(.separator())

        let clickThrough = NSMenuItem(
            title: panel.clickThroughEnabled ? "Stop Click-Through" : "Click-Through",
            action: #selector(toggleClickThrough),
            keyEquivalent: "l"
        )
        clickThrough.keyEquivalentModifierMask = [.command, .option]
        clickThrough.target = self
        menu.addItem(clickThrough)

        menu.addItem(.separator())

        let close = NSMenuItem(title: "Close Pin", action: #selector(closePin), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)

        return menu
    }

    @objc private func copyPin() {
        panel?.onCopy?()
    }

    @objc private func savePin() {
        panel?.onSave?()
    }

    @objc private func closePin() {
        panel?.onClose?()
    }

    @objc private func toggleClickThrough() {
        panel?.toggleClickThrough()
    }
}
