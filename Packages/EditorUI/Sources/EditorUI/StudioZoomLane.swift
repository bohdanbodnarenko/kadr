import AppKit
import StudioSession
import SwiftUI

/// The orange cue strip: drag a range to add a zoom, drag a block to move it,
/// drag a handle to resize, click ticks mark recorded presses.
struct StudioZoomLane: View {
    let model: StudioDocumentModel
    let scale: CGFloat
    let width: CGFloat
    let height: CGFloat

    /// The cue being dragged, and where it started.
    @Binding var dragging: (id: ZoomCue.ID, start: TimeInterval)?
    /// A zoom being drawn on the lane, in edited time.
    @Binding var creating: (start: TimeInterval, end: TimeInterval)?
    /// Frozen ends while a handle is dragged, so each event is not compounded.
    private struct ResizeOrigin {
        var id: ZoomCue.ID
        var start: TimeInterval
        var end: TimeInterval
    }

    @State private var resizing: ResizeOrigin?

    /// Below this many dragged points, a gesture on blank lane space still
    /// scrubs rather than creating a zoom.
    private static let dragCreateThreshold: CGFloat = 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.primary.opacity(0.06)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(createGesture)
                .contextMenu {
                    Button("Add Zoom at Playhead") { model.addZoom() }
                }
                .help("Drag across this lane to add a zoom. Click to scrub.")

            ForEach(Array(model.clickTicks.enumerated()), id: \.offset) { _, time in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: 1, height: 8)
                    .offset(x: time * scale, y: 5)
                    .allowsHitTesting(false)
            }

            if let creating {
                let span = model.proposedZoomSpan(origin: creating.start, current: creating.end)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.orange.opacity(0.35))
                    .frame(width: max((span.high - span.low) * scale, 2), height: height)
                    .offset(x: span.low * scale)
                    .allowsHitTesting(false)
            }

            ForEach(model.edit.zooms) { cue in
                block(for: cue)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.selectedClip = nil
                model.pausePlayback()
                let origin = clamped(value.startLocation.x / scale)
                let now = clamped(value.location.x / scale)
                if creating == nil, abs(value.translation.width) < Self.dragCreateThreshold {
                    model.playhead = now
                    return
                }
                creating = (origin, now)
            }
            .onEnded { _ in
                if let creating {
                    model.addZoom(from: creating.start, to: creating.end)
                }
                creating = nil
            }
    }

    private func block(for cue: ZoomCue) -> some View {
        let span = model.editedDisplayRange(of: cue)
        let selected = model.selectedZoom == cue.id
        let width = max((span.upperBound - span.lowerBound) * scale, 24)
        let running = cue.isEnabled && model.edit.showsZooms
        return HStack(spacing: 0) {
            handle(for: cue, leading: true)
            Text(String(format: "%.1f×", cue.magnification))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            handle(for: cue, leading: false)
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.orange.opacity(running ? (selected ? 0.92 : 0.58) : 0.22))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.primary.opacity(dragging?.id == cue.id ? 0.7 : 0), lineWidth: 1)
        }
        .offset(x: span.lowerBound * scale)
        .help("\(String(format: "%.1f", cue.magnification))× zoom — drag to move, handles to resize")
        .gesture(moveGesture(for: cue))
        .contextMenu {
            Button(cue.isEnabled ? "Disable Zoom" : "Enable Zoom") {
                model.updateZoom(cue.id) { $0.isEnabled.toggle() }
            }
            Button("Remove Zoom", role: .destructive) {
                model.selectedZoom = cue.id
                model.removeSelectedZoom()
            }
        }
    }

    private func handle(for cue: ZoomCue, leading: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(model.selectedZoom == cue.id ? 0.9 : 0.45))
                .frame(width: 2.5, height: 10)
        }
        .frame(width: 20, height: height)
        .contentShape(Rectangle())
        .accessibilityLabel(leading ? "Zoom start" : "Zoom end")
        .accessibilityAddTraits(.isButton)
        .highPriorityGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    model.selectedZoom = cue.id
                    model.pausePlayback()
                    let span = model.editedDisplayRange(of: cue)
                    let origin = resizing ?? ResizeOrigin(id: cue.id, start: span.lowerBound, end: span.upperBound)
                    if resizing == nil {
                        resizing = origin
                    }
                    let delta = value.translation.width / scale
                    if leading {
                        model.setZoomRange(cue.id, start: origin.start + delta, end: origin.end)
                    } else {
                        model.setZoomRange(cue.id, start: origin.start, end: origin.end + delta)
                    }
                }
                .onEnded { _ in resizing = nil }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private func moveGesture(for cue: ZoomCue) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.selectedZoom = cue.id
                let span = model.editedDisplayRange(of: cue)
                let origin = dragging.map(\.start) ?? span.lowerBound
                if dragging == nil {
                    dragging = (cue.id, span.lowerBound)
                }
                model.moveZoom(cue.id, to: origin + value.translation.width / scale)
            }
            .onEnded { _ in dragging = nil }
    }

    private func clamped(_ time: TimeInterval) -> TimeInterval {
        min(max(time, 0), model.edit.duration)
    }
}
