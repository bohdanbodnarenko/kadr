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

    /// The longest edge, in pixels, of the texture loaded or on its way. A resize that
    /// does not change it needs no decode at all.
    private var loadedTarget = 0
    /// The texture on screen, kept so an ⌥-drag can use it rather than decoding again on
    /// mouse-down.
    private var backingImage: CGImage?
    /// The decode in flight, off the main thread. Internal so tests can wait for it.
    private(set) var decodeTask: Task<Void, Never>?
    /// The pending reload for a gesture that has not settled yet.
    private var reloadTask: Task<Void, Never>?
    /// Set while a live resize defers its reload to `viewDidEndLiveResize`.
    private var needsBackingReload = false
    /// How long a zoom has to be still before the sharp texture is fetched.
    private static let reloadSettleMilliseconds = 120
    #if DEBUG
        /// How many times the capture has actually been decoded from disk. The point of
        /// the debounce is that this stays small however much the pin is resized.
        private(set) var decodeCount = 0
        /// Decodes on the calling thread instead, for the memory-budget test: it measures
        /// the textures pins hold, and awaiting background decodes would let every other
        /// test suite run — and allocate — in the middle of the measurement.
        static var decodesInlineForTesting = false
    #endif

    /// Whether a settle-then-reload is waiting, for tests.
    var hasPendingReload: Bool {
        reloadTask != nil
    }

    /// Fired for the menu commands the pin does not implement itself.
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onReveal: (() -> Void)?
    var onAnnotate: (() -> Void)?
    /// Recognises the pin's text and copies it (docs/03 §1.7). The pin holds a file URL,
    /// so the work is the manager's — the panel only offers the command (docs/07 M8).
    var onCopyText: (() -> Void)?
    var onGeometryChanged: (() -> Void)?

    /// Drags the pinned file out to another app. Pins always point at a finalised file,
    /// so the promise has nothing to resolve beyond handing the path over.
    private let dragController = FilePromiseDragController()
    var onClose: (() -> Void)?
    private var hoverBar: PinHoverBar?

    /// - Parameter frame: where a restored pin was, so the panel is built at its final
    ///   size and the first decode is the only one. Nil shows the capture at 1:1.
    init?(fileURL: URL, scale: CGFloat, frame initialFrame: CGRect? = nil) {
        guard let pixelSize = ThumbnailLoader().pixelSize(for: fileURL) else { return nil }
        self.fileURL = fileURL
        self.pixelSize = pixelSize

        // Shown at captured size: pixels divided by the display scale gives points.
        let width = CGFloat(pixelSize.width) / scale
        let height = CGFloat(pixelSize.height) / scale
        let contentRect = initialFrame.flatMap { $0.isEmpty ? nil : $0 }
            ?? CGRect(x: 0, y: 0, width: width, height: height)

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        configureAsOverlay(level: .floating)
        hasShadow = true
        contentAspectRatio = NSSize(width: width, height: height)
        let shortest: CGFloat = 80
        if width >= height {
            minSize = NSSize(width: shortest, height: shortest * height / max(width, 1))
        } else {
            minSize = NSSize(width: shortest * width / max(height, 1), height: shortest)
        }
        // Pins are reference layers the user arranges by hand.
        isMovableByWindowBackground = true
        // On every Space, because a reference you have to chase between Spaces is useless.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = CGRect(origin: .zero, size: contentRect.size)
        imageView.autoresizingMask = [.width, .height]

        let container = PinContentView(frame: imageView.frame)
        container.panel = self
        container.addSubview(imageView)
        contentView = container

        reloadBackingImage()
        configureAccessibility()
        hoverBar = PinHoverBar(panel: self)
        if let hoverBar {
            contentView?.addSubview(hoverBar)
        }
    }

    func setHoverBarVisible(_ visible: Bool) {
        hoverBar?.setVisible(visible)
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
        reloadTask?.cancel()
        reloadTask = nil
        decodeTask?.cancel()
        decodeTask = nil
        backingImage = nil
        hoverBar?.removeFromSuperview()
        hoverBar = nil
        contentView = nil
        imageView.image = nil
        orderOut(nil)
        close()
    }

    // MARK: - Backing image

    /// Loads a texture sized for the panel, not the capture (docs/03 §4).
    ///
    /// Reloaded whenever the panel settles at a new size so a pin scaled up stays sharp,
    /// and dropped back down when it shrinks so the memory goes with it.
    func reloadBackingImage() {
        reloadTask?.cancel()
        reloadTask = nil
        needsBackingReload = false

        let scale = screen?.backingScaleFactor ?? 2
        let longestEdge = max(frame.width, frame.height) * scale * max(1, zoom)
        // Never ask for more pixels than the capture actually has.
        let target = min(Int(longestEdge.rounded()), max(pixelSize.width, pixelSize.height))
        guard target != loadedTarget else {
            // Same texture, new frame: stretching the one we have is free.
            imageView.image?.size = frame.size
            return
        }

        // Claimed now, so a resize while the decode runs does not start a second one for
        // the same size.
        let previousTarget = loadedTarget
        loadedTarget = target
        #if DEBUG
            decodeCount += 1
        #endif
        decodeTask?.cancel()
        let loader = loader
        let url = fileURL
        #if DEBUG
            if Self.decodesInlineForTesting {
                decodeTask = nil
                applyDecoded(loader.thumbnail(for: url, maxPixelSize: target), previousTarget: previousTarget)
                return
            }
        #endif
        // Off the main thread: a pin restored at launch, or zoomed on a 5K capture, is an
        // ImageIO decode of tens of megabytes of PNG. The texture already on screen (or
        // the empty panel) stays until the new one is ready.
        decodeTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                loader.thumbnail(for: url, maxPixelSize: target)
            }.value
            guard let self, !Task.isCancelled, loadedTarget == target else { return }
            decodeTask = nil
            applyDecoded(image, previousTarget: previousTarget)
        }
    }

    private func applyDecoded(_ image: CGImage?, previousTarget: Int) {
        guard let image else {
            loadedTarget = previousTarget
            logger.error("Could not load a backing image for \(self.fileURL.lastPathComponent, privacy: .public)")
            return
        }
        backingImage = image
        imageView.image = NSImage(cgImage: image, size: frame.size)
    }

    /// Asks for a reload once the user stops resizing or zooming.
    ///
    /// A live resize delivers a frame change per screen refresh and a scroll-zoom one per
    /// tick; decoding the capture from disk on each of them made dragging a pin's corner
    /// stutter and re-read a 5K PNG sixty times a second (docs/07 M9). The texture already
    /// on screen stretches perfectly well until the gesture ends.
    private func scheduleBackingReload() {
        imageView.image?.size = frame.size
        guard !inLiveResize else {
            // AppKit tells us when the drag ends; nothing to poll for.
            needsBackingReload = true
            return
        }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.reloadSettleMilliseconds))
            guard !Task.isCancelled else { return }
            self?.reloadBackingImage()
        }
    }

    /// Reloads if a gesture deferred one. Called when a live resize ends.
    func reloadBackingImageIfNeeded() {
        guard needsBackingReload else { return }
        reloadBackingImage()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let changed = frameRect.size != frame.size
        super.setFrame(frameRect, display: flag)
        if changed {
            scheduleBackingReload()
        }
        if !inLiveResize {
            onGeometryChanged?()
        }
    }

    // MARK: - Zoom and opacity (docs/03 §4)

    /// ⌥-scroll zooms; plain scroll adjusts opacity between 20% and 100%.
    func handleScroll(_ event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            setZoom(zoom * (1 + event.scrollingDeltaY / 200))
        } else {
            alphaValue = min(max(alphaValue + event.scrollingDeltaY / 200, 0.2), 1)
            updateAccessibilityDescription()
            onGeometryChanged?()
        }
    }

    /// Starts a file-promise drag of the pinned capture (docs/03 §6).
    ///
    /// The drag image is the texture the pin already shows, scaled to the same 256 pt the
    /// drag used to decode for itself — on mouse-down, on the main thread.
    func beginFileDrag(from view: NSView, event: NSEvent) {
        dragController.beginDrag(
            from: view,
            event: event,
            payload: .file(at: fileURL),
            image: backingImage.map { NSImage(cgImage: $0, size: Self.dragImageSize(for: $0)) }
        )
    }

    private static let dragImageLongestEdge: CGFloat = 256

    static func dragImageSize(for image: CGImage) -> NSSize {
        let longest = CGFloat(max(image.width, image.height, 1))
        let factor = min(1, dragImageLongestEdge / longest)
        return NSSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
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
        updateAccessibilityDescription()
    }

    /// Arrow keys nudge the pin, ⇧ by ten points (docs/03 §4).
    func nudge(dx: CGFloat, dy: CGFloat) {
        setFrameOrigin(CGPoint(x: frame.origin.x + dx, y: frame.origin.y + dy))
        onGeometryChanged?()
    }

    /// Restores frame, opacity and lock mode from the last session (docs/03 §4 P2).
    func applyPersistedState(frame: CGRect, alpha: Double, clickThrough: Bool) {
        setFrame(frame, display: false)
        alphaValue = min(max(alpha, 0.2), 1)
        if clickThrough != isClickThrough {
            toggleClickThrough()
        }
    }

    /// Hide without closing, so the pin is not clickable while tucked away (CleanShot §11).
    func hideForStack() {
        ignoresMouseEvents = true
        orderOut(nil)
    }

    func revealFromStack() {
        ignoresMouseEvents = isClickThrough
        orderFrontRegardless()
    }

    /// Middle-click closes the pin without taking it through the context menu (CleanShot §11).
    func closeFromMiddleClick() {
        onClose?()
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
        updateAccessibilityDescription()
        refreshAccessibilityActions()
        let announcement = isClickThrough
            ? String(localized: "Click-through on. Press Command Option L to interact.")
            : String(localized: "Click-through off.")
        FeedbackAnnouncement.post(announcement)
        hoverBar?.setVisible(false)
        onGeometryChanged?()
    }

    var clickThroughEnabled: Bool {
        isClickThrough
    }

    private func configureAccessibility() {
        imageView.setAccessibilityElement(true)
        imageView.setAccessibilityRole(.image)
        imageView.setAccessibilityHelp(
            String(localized: "Press Command Option L to toggle click-through.")
        )
        updateAccessibilityDescription()
        refreshAccessibilityActions()
    }

    private func refreshAccessibilityActions() {
        let clickThroughTitle = isClickThrough
            ? String(localized: "Stop Click-Through")
            : String(localized: "Toggle Click-Through")
        imageView.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Copy", target: self, selector: #selector(accessibilityCopy)),
            NSAccessibilityCustomAction(name: "Save", target: self, selector: #selector(accessibilitySave)),
            NSAccessibilityCustomAction(name: "Annotate", target: self, selector: #selector(accessibilityAnnotate)),
            NSAccessibilityCustomAction(name: "Copy Text", target: self, selector: #selector(accessibilityCopyText)),
            NSAccessibilityCustomAction(
                name: clickThroughTitle,
                target: self,
                selector: #selector(accessibilityToggleClickThrough)
            ),
            NSAccessibilityCustomAction(name: "Close", target: self, selector: #selector(accessibilityClose))
        ])
    }

    @objc private func accessibilityCopy() {
        onCopy?()
    }

    @objc private func accessibilitySave() {
        onSave?()
    }

    @objc private func accessibilityAnnotate() {
        onAnnotate?()
    }

    @objc private func accessibilityCopyText() {
        onCopyText?()
    }

    @objc private func accessibilityToggleClickThrough() {
        toggleClickThrough()
    }

    @objc private func accessibilityClose() {
        onClose?()
    }

    private func updateAccessibilityDescription() {
        let filename = fileURL.lastPathComponent
        let dimensions = "\(pixelSize.width) × \(pixelSize.height)"
        let zoomPercent = Int((zoom * 100).rounded())
        let opacityPercent = Int((alphaValue * 100).rounded())
        let clickThrough = isClickThrough
            ? String(localized: "click-through on")
            : String(localized: "click-through off")
        imageView.setAccessibilityLabel(
            "\(filename), \(dimensions), \(zoomPercent) percent zoom, "
                + "\(opacityPercent) percent opacity, \(clickThrough)"
        )
        imageView.setAccessibilityValue(clickThrough)
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
