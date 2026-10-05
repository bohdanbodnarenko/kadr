import SwiftUI

/// A map of the recording for placing a zoom, not a second copy of the preview.
///
/// The dot is where the zoom points. The outlined rectangle is the slice still visible at
/// that magnification. Dragging here is how a cue's target is aimed; typing pixel
/// coordinates is not.
struct StudioZoomFocusPad: View {
    @Binding var position: CGPoint
    let magnification: Double
    let aspect: CGSize

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let size = fittedSize(in: proxy.size)
            let origin = CGPoint(
                x: (proxy.size.width - size.width) / 2,
                y: (proxy.size.height - size.height) / 2
            )
            let target = CGPoint(
                x: origin.x + clamped(position.x) * size.width,
                y: origin.y + clamped(position.y) * size.height
            )
            let zoom = max(magnification, 1)
            let viewport = CGSize(width: size.width / zoom, height: size.height / zoom)
            let viewportCenter = CGPoint(
                x: min(max(target.x, origin.x + viewport.width / 2), origin.x + size.width - viewport.width / 2),
                y: min(max(target.y, origin.y + viewport.height / 2), origin.y + size.height - viewport.height / 2)
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: size.width, height: size.height)
                    .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)

                Path { path in
                    path.move(to: CGPoint(x: origin.x + size.width / 2, y: origin.y))
                    path.addLine(to: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height))
                    path.move(to: CGPoint(x: origin.x, y: origin.y + size.height / 2))
                    path.addLine(to: CGPoint(x: origin.x + size.width, y: origin.y + size.height / 2))
                }
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                    .frame(width: viewport.width, height: viewport.height)
                    .position(x: viewportCenter.x, y: viewportCenter.y)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: isDragging ? 11 : 9, height: isDragging ? 11 : 9)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.25))
                    .position(target)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        guard size.width > 0, size.height > 0 else { return }
                        position = CGPoint(
                            x: clamped((value.location.x - origin.x) / size.width),
                            y: clamped((value.location.y - origin.y) / size.height)
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) {
                position = CGPoint(x: 0.5, y: 0.5)
            }
        }
        .frame(height: 112)
        .help("Drag to aim the zoom. The outline is what stays on screen. Double-click centers it.")
        .accessibilityLabel("Zoom target")
        .accessibilityHint("Drag to move the target. Double-click to center.")
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        let ratio = max(aspect.width, 1) / max(aspect.height, 1)
        var size = container
        if size.width / max(size.height, 1) > ratio {
            size.width = size.height * ratio
        } else {
            size.height = size.width / ratio
        }
        return size
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}
