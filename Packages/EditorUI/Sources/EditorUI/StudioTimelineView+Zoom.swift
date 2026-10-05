import SwiftUI

extension StudioTimelineView {
    func zoomControls(viewportWidth: CGFloat) -> some View {
        HStack(spacing: 2) {
            zoomIcon(
                "minus.magnifyingglass",
                label: "Zoom timeline out",
                help: "Show more of the recording (⌘-)"
            ) {
                applyZoom(factor: 1 / StudioTimelineZoom.step, pointerX: nil, viewportWidth: viewportWidth)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= 1.0001)

            zoomIcon(
                "plus.magnifyingglass",
                label: "Zoom timeline in",
                help: "Stretch the timeline for a closer cut (⌘=)"
            ) {
                applyZoom(factor: StudioTimelineZoom.step, pointerX: nil, viewportWidth: viewportWidth)
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(zoom >= StudioTimelineZoom.maximum - 0.0001)

            zoomIcon(
                "arrow.left.and.right",
                label: "Fit timeline to window",
                help: "Fit the whole recording (⌘0)"
            ) {
                applyZoom(factor: 1 / max(zoom, 1), pointerX: nil, viewportWidth: viewportWidth)
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(zoom <= 1.0001)

            if zoom > 1.0001 {
                Text(StudioMultiplier.text(zoom))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            Spacer(minLength: 0)
        }
    }

    func zoomIcon(
        _ symbol: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
    }

    /// Stretches around the pointer when we know it, otherwise around the hovered time or
    /// the playhead — so pinch / ⌘-scroll / ⌘= do not shove the cut off the screen.
    func applyZoom(factor: CGFloat, pointerX: CGFloat?, viewportWidth: CGFloat) {
        let next = StudioTimelineZoom.clamp(zoom * factor)
        guard abs(next - zoom) > 0.0001 else { return }
        if next <= 1 {
            zoomAnchorTime = 0
            zoomAnchorFraction = 0
        } else {
            zoomAnchorTime = hoverTime ?? model.playhead
            if let pointerX {
                zoomAnchorFraction = StudioTimelineZoom.viewportFraction(
                    pointerX: pointerX,
                    viewportWidth: viewportWidth
                )
            } else {
                zoomAnchorFraction = 0.5
            }
        }
        zoom = next
    }
}
