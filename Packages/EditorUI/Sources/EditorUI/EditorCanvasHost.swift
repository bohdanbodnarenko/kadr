import AnnotationModel
import AppKit
import Shared
import SwiftUI

/// Hosts the CALayer canvas inside SwiftUI, fitted and centered in the remaining space.
struct EditorCanvasHost: NSViewRepresentable {
    let model: EditorDocumentModel
    let baseImage: CGImage
    let session: EditorCanvasSession
    var isCropping: Bool
    var zoomToFit: Bool

    func makeNSView(context: Context) -> EditorCanvasScrollView {
        let canvas = AnnotationCanvasView(model: model, baseImage: baseImage)
        let scrollView = EditorCanvasScrollView()
        let clipView = CenteringClipView(frame: .zero)
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = EditorCanvasLayout.minMagnification
        scrollView.maxMagnification = EditorCanvasLayout.maxMagnification
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.usesPredominantAxisScrolling = false
        scrollView.postsFrameChangedNotifications = true

        context.coordinator.canvas = canvas
        context.coordinator.scrollView = scrollView
        context.coordinator.session = session
        scrollView.onMagnificationChanged = { [weak session] value in
            session?.noteLiveMagnification(value)
        }
        scrollView.onZoomed = { [weak session] value in
            session?.noteLiveMagnification(value)
        }
        context.coordinator.startObserving(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: EditorCanvasScrollView, context: Context) {
        // Fit is applied from the session and the viewport, not from a SwiftUI-bound
        // magnification: pushing live fit values back through the representable re-laid
        // the canvas on every window-resize tick and made the capture jump.
        _ = zoomToFit
        context.coordinator.session = session
        context.coordinator.isCropping = isCropping
        context.coordinator.syncCanvasIfNeeded(model: model)
        context.coordinator.apply()
    }

    static func dismantleNSView(_ nsView: EditorCanvasScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
        nsView.onMagnificationChanged = nil
        nsView.onZoomed = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var canvas: AnnotationCanvasView?
        weak var scrollView: EditorCanvasScrollView?
        weak var session: EditorCanvasSession?
        var isCropping = false
        /// Last document the canvas was told about, so a SwiftUI body refresh that only
        /// touched inspector memory does not tear down every annotation layer.
        private var syncKey: CanvasSyncKey?

        /// Avoid echoing a magnification we just wrote back through the pinch callback.
        private var isApplying = false
        private var lastFitKey: FitKey?
        private var frameObserver: NSObjectProtocol?
        private var magnifyEndObserver: NSObjectProtocol?

        func startObserving(_ scrollView: EditorCanvasScrollView) {
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.apply()
                }
            }
            magnifyEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scrollView?.isUserMagnifying = false
                    self?.apply()
                }
            }
        }

        func tearDown() {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            if let magnifyEndObserver {
                NotificationCenter.default.removeObserver(magnifyEndObserver)
            }
            frameObserver = nil
            magnifyEndObserver = nil
        }

        func syncCanvasIfNeeded(model: EditorDocumentModel) {
            let key = CanvasSyncKey(
                commands: model.document.commands,
                selection: model.document.selection,
                candidates: model.redactionCandidates,
                tool: model.tool
            )
            guard syncKey != key else { return }
            syncKey = key
            canvas?.documentChangedExternally()
        }

        func apply() {
            guard let session, let scrollView, let canvas, !isApplying else { return }
            guard scrollView.isUserMagnifying == false else { return }

            // Frame, not bounds: magnification shrinks clip-view bounds into document
            // space, and fitting against that would compound and collapse the image.
            let viewport = scrollView.contentView.frame.size
            guard viewport.width > 1, viewport.height > 1 else { return }

            let canvasSize = canvas.frame.size
            let target: CGFloat
            if session.zoomToFit {
                let key = FitKey(canvas: canvasSize, viewport: viewport, isCropping: isCropping)
                target = EditorCanvasLayout.fitMagnification(
                    canvas: canvasSize,
                    viewport: viewport,
                    isCropping: isCropping
                )
                if lastFitKey != key {
                    lastFitKey = key
                    session.noteFittedMagnification(target)
                }
            } else {
                lastFitKey = nil
                target = EditorCanvasLayout.clampMagnification(session.magnification)
            }

            isApplying = true
            defer { isApplying = false }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            defer { NSAnimationContext.endGrouping() }

            if abs(scrollView.magnification - target) > 0.002 {
                if session.zoomToFit {
                    // Fit re-centres by definition, so a plain assignment is right — and it
                    // avoids the centred API recentring during a live window resize, which
                    // is the jump the previous comment here was about.
                    scrollView.magnification = target
                } else {
                    // Anchored at the middle of what the user is looking at.
                    //
                    // A plain assignment magnifies about the clip view's *origin*, so ⌘- did
                    // not zoom out from the centre — it walked the visible region towards the
                    // top-left corner and, past the point where the canvas fits, dumped it
                    // there. That is the jump: not a glitch, the documented behaviour of
                    // assigning to `magnification`.
                    scrollView.setMagnification(target, centeredAt: scrollView.viewportCentre)
                }
            }
            (scrollView.contentView as? CenteringClipView)?.recenterDocument()
            // Rasterise the vector chrome for the density it is now being seen at.
            canvas.updateContentsScale(forMagnification: scrollView.magnification)

            let overflowing = EditorCanvasLayout.canPan(
                canvas: canvasSize,
                viewport: viewport,
                magnification: scrollView.magnification
            )
            scrollView.hasVerticalScroller = overflowing
            scrollView.hasHorizontalScroller = overflowing
            scrollView.verticalScrollElasticity = overflowing ? .automatic : .none
            scrollView.horizontalScrollElasticity = overflowing ? .automatic : .none
        }

        private struct FitKey: Equatable {
            var canvas: CGSize
            var viewport: CGSize
            var isCropping: Bool
        }
    }
}

/// Centers the document when it is smaller than the clip view (the default NSClipView
/// parks it at the origin, which is the top-left of a flipped canvas).
final class CenteringClipView: NSClipView {
    override var isFlipped: Bool {
        documentView?.isFlipped ?? true
    }

    override var isOpaque: Bool {
        false
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: clampedOrigin(newOrigin))
    }

    func recenterDocument() {
        scroll(to: bounds.origin)
    }

    private func clampedOrigin(_ proposed: NSPoint) -> NSPoint {
        guard let documentView else { return proposed }
        return EditorCanvasLayout.clipOrigin(
            document: documentView.frame.size,
            clip: bounds.size,
            proposed: proposed
        )
    }
}

/// Pinch, ⌘-scroll zoom, and a callback when the user leaves "fit" by magnifying.
final class EditorCanvasScrollView: NSScrollView {
    var onMagnificationChanged: ((CGFloat) -> Void)?
    /// Reports a magnification this view performed itself, so the session can follow.
    var onZoomed: ((CGFloat) -> Void)?
    var isUserMagnifying = false

    override var isOpaque: Bool {
        false
    }

    /// The middle of the visible region, in the coordinates `setMagnification` wants.
    var viewportCentre: CGPoint {
        CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    }

    /// Zooms about a fixed point, so whatever is under it stays under it.
    ///
    /// The anchor is the whole feature. Without one, zooming is a scale about the corner of
    /// the document and the thing the user was looking at slides away — which on the way out
    /// ends with the canvas parked at the top-left.
    func zoom(by factor: CGFloat, at point: CGPoint) {
        let target = EditorCanvasLayout.clampMagnification(magnification * factor)
        guard abs(target - magnification) > 0.0001 else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        setMagnification(target, centeredAt: point)
        NSAnimationContext.endGrouping()
        onZoomed?(magnification)
    }

    override func magnify(with event: NSEvent) {
        isUserMagnifying = true
        super.magnify(with: event)
        onMagnificationChanged?(magnification)
    }

    override func smartMagnify(with event: NSEvent) {
        super.smartMagnify(with: event)
        onMagnificationChanged?(magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        let step = min(max(1 + delta * 0.004, 0.85), 1.15)
        // Under the pointer, which is where a ⌘-scroll zoom is expected to happen: the
        // gesture names its own anchor, so zooming in on a detail should not require
        // scrolling back to it afterwards.
        zoom(by: step, at: contentView.convert(event.locationInWindow, from: nil))
    }
}

/// What the canvas actually draws. Inspector style memory is not in here, so picking a
/// colour for the *next* stroke does not rebuild every layer already on screen.
private struct CanvasSyncKey: Equatable {
    var commands: [AnnotationCommand]
    var selection: Set<AnnotationID>
    var candidates: [RedactionCandidate]
    var tool: EditorTool
}
