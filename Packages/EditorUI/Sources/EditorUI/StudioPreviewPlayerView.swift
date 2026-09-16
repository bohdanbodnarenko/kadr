import AppKit
import AVFoundation
import SwiftUI

/// The studio picture, straight from the player (docs/09 U3.3).
///
/// An `AVPlayerLayer` as the view's own backing layer: the compositor's IOSurfaces go to the
/// window server without being read back, which is the whole difference between this and
/// the `CGImage`-per-frame preview it replaced. AppKit owns the layer; SwiftUI only places
/// it (CLAUDE.md rule 4).
struct StudioPreviewPlayerView: NSViewRepresentable {
    let player: AVPlayer?
    /// Reports the view's size in points and its window's backing scale, whenever either
    /// changes — the preview is rendered at that many pixels, bucketed.
    let onResize: @MainActor (CGSize, CGFloat) -> Void

    func makeNSView(context _: Context) -> StudioPreviewPlayerNSView {
        let view = StudioPreviewPlayerNSView()
        view.onResize = onResize
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: StudioPreviewPlayerNSView, context _: Context) {
        view.onResize = onResize
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleNSView(_ view: StudioPreviewPlayerNSView, coordinator _: ()) {
        // The layer must not keep the player — and through it the decoder — alive after the
        // preview has gone.
        view.playerLayer.player = nil
        view.onResize = nil
    }
}

/// A layer-hosting view whose layer is the player's.
final class StudioPreviewPlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var onResize: (@MainActor (CGSize, CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.cornerRadius = 10
        playerLayer.cornerCurve = .continuous
        playerLayer.masksToBounds = true
        // Layer-hosting rather than layer-backed: the layer is ours, and AppKit must not
        // replace it or draw into it.
        layer = playerLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Nothing to hit: the overlays above handle the pointer.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        reportSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The window's own scale, not the main screen's: a studio window dragged onto a
        // non-Retina display needs half the pixels.
        playerLayer.contentsScale = window?.backingScaleFactor ?? 2
        reportSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportSize()
    }

    private func reportSize() {
        guard let window else { return }
        onResize?(bounds.size, window.backingScaleFactor)
    }
}
