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
    var magnification: CGFloat

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
        scrollView.onCommandScrollZoom = { [weak session] factor in
            guard let session else { return }
            session.setMagnification(session.magnification * factor)
        }
        context.coordinator.startObserving(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: EditorCanvasScrollView, context: Context) {
        // `zoomToFit` and `magnification` are read so SwiftUI rebuilds the representable
        // when the HUD changes them. The coordinator then copies them onto the scroll view.
        _ = (zoomToFit, magnification)
        context.coordinator.session = session
        context.coordinator.isCropping = isCropping
        context.coordinator.syncCanvasIfNeeded(model: model)
        context.coordinator.apply()
    }

    static func dismantleNSView(_ nsView: EditorCanvasScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
        nsView.onMagnificationChanged = nil
        nsView.onCommandScrollZoom = nil
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

            if abs(scrollView.magnification - target) > 0.002 {
                let clip = scrollView.contentView
                scrollView.setMagnification(
                    target,
                    centeredAt: CGPoint(x: clip.bounds.midX, y: clip.bounds.midY)
                )
            }
            (scrollView.contentView as? CenteringClipView)?.recenterDocument()

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
    var onCommandScrollZoom: ((CGFloat) -> Void)?
    var isUserMagnifying = false

    override var isOpaque: Bool {
        false
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
        onCommandScrollZoom?(step)
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
