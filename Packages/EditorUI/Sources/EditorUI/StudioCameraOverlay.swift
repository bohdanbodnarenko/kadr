import AppKit
import StudioSession
import SwiftUI

/// A hit target over the composed webcam so it can be dragged — a talking-head bubble is
/// placed by moving it, not by picking a named corner.
///
/// The corner handle is extra, in place of a size slider in the inspector. Dragging the
/// corner here resizes it on the picture, pinning the opposite edge so the handle follows
/// the pointer.
struct StudioCameraOverlay: View {
    let model: StudioDocumentModel
    let fitted: CGRect
    let imageSize: CGSize

    @State private var dragOrigin: CGPoint?
    @State private var pinnedOrigin: CGPoint?
    @State private var startSide: CGFloat?
    @State private var isHovering = false

    var body: some View {
        let bubble = viewRect
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(isHovering ? 0.85 : 0.35), lineWidth: 1.5)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.white.opacity(0.001))
                }
                .gesture(moveGesture)
            if isHovering {
                resizeHandle
            }
        }
        .frame(width: bubble.width, height: bubble.height)
        .position(x: bubble.midX, y: bubble.midY)
        .onHover { isHovering = $0 }
        .help("Drag to move the camera. Drag the corner to resize.")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = model.edit.camera.normalizedCenter(in: imageSize)
                }
                guard let dragOrigin, fitted.width > 0, fitted.height > 0 else { return }
                model.moveCamera(toNormalizedCenter: CGPoint(
                    x: dragOrigin.x + value.translation.width / fitted.width,
                    y: dragOrigin.y + value.translation.height / fitted.height
                ))
            }
            .onEnded { _ in
                dragOrigin = nil
            }
    }

    private var resizeHandle: some View {
        Circle()
            .fill(.white)
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .frame(width: 22, height: 22, alignment: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(resizeGesture)
            .onHover { hovering in
                if hovering {
                    NSCursor.crosshair.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .help("Drag to resize")
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if pinnedOrigin == nil {
                    let frame = model.edit.camera.frame(in: imageSize)
                    pinnedOrigin = CGPoint(x: frame.minX, y: frame.minY)
                    startSide = viewRect.width
                }
                guard let startSide else { return }
                let next = max(startSide + (value.translation.width + value.translation.height) / 2, 8)
                model.resizeCamera(
                    toSizeFraction: sizeFraction(forViewSide: next),
                    pinningTopLeading: pinnedOrigin ?? .zero
                )
            }
            .onEnded { _ in
                pinnedOrigin = nil
                startSide = nil
            }
    }

    private var viewRect: CGRect {
        let pixel = model.edit.camera.frame(in: imageSize)
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        return CGRect(
            x: fitted.minX + pixel.minX / imageSize.width * fitted.width,
            y: fitted.minY + pixel.minY / imageSize.height * fitted.height,
            width: pixel.width / imageSize.width * fitted.width,
            height: pixel.height / imageSize.height * fitted.height
        )
    }

    private var cornerRadius: CGFloat {
        guard imageSize.width > 0 else { return 0 }
        return model.edit.camera.cornerRadius(in: imageSize) / imageSize.width * fitted.width
    }

    private func sizeFraction(forViewSide side: CGFloat) -> Double {
        guard fitted.width > 0, imageSize.width > 0 else { return model.edit.camera.sizeFraction }
        let pixelSide = side / fitted.width * imageSize.width
        let shortest = min(imageSize.width, imageSize.height)
        guard shortest > 0 else { return model.edit.camera.sizeFraction }
        return pixelSide / shortest
    }
}
