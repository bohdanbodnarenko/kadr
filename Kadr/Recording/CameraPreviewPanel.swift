import AppKit
import AVFoundation
import OverlayKit

/// A circular live view of the webcam, excluded from the recording it sits on.
///
/// Shown as soon as the camera is armed in the picker, so the exposure ramp finishes
/// before the file starts — and kept up during Area and Window selection, when the
/// control bar itself is hidden. Movable, so it can be dragged off the thing being filmed.
@MainActor
final class CameraPreviewPanel {
    static let diameter: CGFloat = 160
    private static let margin: CGFloat = 24

    /// Where the user last dragged it, so it comes back where they put it.
    static var savedOrigin: CGPoint?

    private var panel: NonActivatingPanel?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    var isShowing: Bool {
        panel != nil
    }

    /// Puts the bubble on screen, attached to an already-running capture session.
    func show(session: AVCaptureSession) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let diameter = Self.diameter
        let frame = CGRect(origin: origin(for: diameter), size: CGSize(width: diameter, height: diameter))
        let panel = CameraPreviewBubblePanel(contentRect: frame, level: .floating)
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        CaptureExclusionRegistry.shared.register(panel)

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = diameter / 2
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        container.layer?.borderWidth = 1

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = container.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        container.layer?.addSublayer(preview)

        panel.contentView = container
        panel.orderFrontRegardless()
        self.panel = panel
        previewLayer = preview
    }

    func hide() {
        guard let panel else { return }
        Self.savedOrigin = panel.frame.origin
        CaptureExclusionRegistry.shared.unregister(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        previewLayer = nil
    }

    private func origin(for diameter: CGFloat) -> CGPoint {
        if let saved = Self.savedOrigin {
            return saved
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        return CGPoint(
            x: visible.maxX - diameter - Self.margin,
            y: visible.minY + Self.margin
        )
    }
}

/// A bubble that must never take the keyboard away from the app being recorded.
private final class CameraPreviewBubblePanel: NonActivatingPanel {
    override var canBecomeKey: Bool {
        false
    }
}
