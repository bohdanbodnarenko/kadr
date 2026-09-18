import AppKit
import StudioSession
import SwiftUI

/// The orange cue strip: drag a range to add a zoom, drag a block to move it,
/// drag a handle to resize, click ticks mark recorded presses.
///
/// Suggested zooms sit underneath as dashed outlines wherever the recording has a cluster
/// of clicks and nothing is zoomed yet — the places a zoom most likely belongs, visible at a
/// glance. Click one to keep it; right-click to dismiss it. A block shows how it aims, a ×
/// on hover removes it, and a double-click plays it.
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
        /// The cue's move time when the drag began, so shrinking and growing it again in
        /// one drag gives the original moves back rather than ratcheting them down.
        var transition: TimeInterval
    }

    /// Drags are measured in the timeline's own space, not the block's.
    ///
    /// A block moves while it is dragged. In its local space every event's translation
    /// was pointer travel *minus* how far the block itself had just moved, so a resized or
    /// moved zoom fought the pointer and jumped. The bands' named space stays put.
    private static let dragSpace = CoordinateSpace.named(StudioTimelinePlayhead.coordinateSpace)

    /// Model changes from a drag land without animation: the block has to track the
    /// pointer, not ease towards it.
    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    @State private var resizing: ResizeOrigin?
    @State private var isHovering = false

    /// Below this many dragged points, a gesture on blank lane space is a click, which
    /// adds a zoom of the default length there.
    private static let dragCreateThreshold: CGFloat = 4

    var body: some View {
        let suggestions = model.zoomSuggestions
        return ZStack(alignment: .topLeading) {
            Color.primary.opacity(0.06)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(createGesture)
                .onHover { isHovering = $0 }
                .contextMenu { laneMenu(suggestions: suggestions) }
                .help("Click to add a zoom here, or drag to set its length. Z adds one at the pointer.")

            if isHovering, creating == nil, dragging == nil, resizing == nil {
                StudioZoomAddGhost(
                    model: model,
                    clock: model.playheadClock,
                    scale: scale,
                    height: height,
                    avoiding: suggestions.map { model.editedDisplayRange(of: $0) }
                )
            }

            if model.edit.zooms.isEmpty, suggestions.isEmpty, creating == nil, !isHovering {
                Text("Click or drag here to add a zoom")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
                    .frame(height: height)
                    .allowsHitTesting(false)
            }

            ForEach(suggestions) { cue in
                suggestion(for: cue)
            }

            ForEach(Array(model.clickTicks.enumerated()), id: \.offset) { _, time in
                Circle()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: 4, height: 4)
                    .offset(x: time * scale - 2, y: height - 6)
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
                let origin = clamped(value.startLocation.x / scale)
                let now = clamped(value.location.x / scale)
                guard creating != nil || abs(value.translation.width) >= Self.dragCreateThreshold else {
                    return
                }
                if creating == nil {
                    model.selectedClip = nil
                    model.pausePlayback()
                }
                creating = (origin, now)
            }
            .onEnded { value in
                if let creating {
                    model.addZoom(from: creating.start, to: creating.end)
                } else {
                    // A click: the zoom the hover preview was showing.
                    model.pausePlayback()
                    model.addOrSelectZoom(at: clamped(value.startLocation.x / scale))
                }
                creating = nil
            }
    }

    @ViewBuilder
    private func laneMenu(suggestions: [ZoomCue]) -> some View {
        Button("Add Zoom at Playhead") { model.addOrSelectZoom(at: model.playhead) }
        if !suggestions.isEmpty {
            Button("Add All \(suggestions.count) Suggested Zooms") { model.addSuggestedZooms() }
        }
        Divider()
        Toggle("Show Suggested Zooms", isOn: Binding(
            get: { model.showsZoomSuggestions },
            set: { model.showsZoomSuggestions = $0 }
        ))
        if !model.dismissedZoomSuggestions.isEmpty {
            Button("Restore Dismissed Suggestions") { model.restoreDismissedZoomSuggestions() }
        }
    }

    /// A zoom the clicks suggest: a dashed outline, added with one click.
    private func suggestion(for cue: ZoomCue) -> some View {
        let span = model.editedDisplayRange(of: cue)
        let width = max((span.upperBound - span.lowerBound) * scale, 16)
        let clicks = model.clickCount(in: cue)
        return Button {
            model.acceptZoomSuggestion(cue)
        } label: {
            StudioZoomSuggestionLabel(width: width, height: height)
        }
        .buttonStyle(.plain)
        .offset(x: span.lowerBound * scale)
        .help("Suggested zoom — \(clicks) click\(clicks == 1 ? "" : "s") here. Click to add it.")
        .accessibilityLabel("Suggested zoom at \(StudioClock.precise(span.lowerBound))")
        .accessibilityHint("Adds this zoom")
        .contextMenu {
            Button("Add This Zoom") { model.acceptZoomSuggestion(cue) }
            Button("Dismiss Suggestion") { model.dismissZoomSuggestion(cue) }
            Divider()
            Button("Add All Suggested Zooms") { model.addSuggestedZooms() }
        }
    }

    private func block(for cue: ZoomCue) -> some View {
        let span = model.editedDisplayRange(of: cue)
        let selected = model.selectedZoom == cue.id
        let width = max((span.upperBound - span.lowerBound) * scale, 24)
        let running = cue.isEnabled && model.edit.showsZooms
        return HStack(spacing: 0) {
            handle(for: cue, leading: true)
            StudioZoomBlockLabel(
                cue: cue,
                focus: model.zoomFocus(of: cue.id),
                showsDetail: width >= 70,
                isDragging: dragging?.id == cue.id || resizing?.id == cue.id,
                remove: { remove(cue) }
            )
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
        .help(
            "\(String(format: "%.1f", cue.magnification))× zoom — drag to move, handles to resize, double-click to play"
        )
        .gesture(moveGesture(for: cue))
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.previewZoom(cue.id) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(String(format: "%.1f", cue.magnification))× zoom at \(StudioClock.precise(span.lowerBound))"
        )
        .accessibilityAction(named: "Play") { model.previewZoom(cue.id) }
        .accessibilityAction(named: "Remove") { remove(cue) }
        .contextMenu {
            Button("Play This Zoom") { model.previewZoom(cue.id) }
            Button(cue.isEnabled ? "Disable Zoom" : "Enable Zoom") {
                model.updateZoom(cue.id) { $0.isEnabled.toggle() }
            }
            Menu("Focus") {
                ForEach(StudioZoomFocus.allCases, id: \.self) { focus in
                    Button(focus.title) { model.setZoomFocus(cue.id, to: focus) }
                }
            }
            Divider()
            Button("Remove Zoom", role: .destructive) { remove(cue) }
        }
    }

    private func remove(_ cue: ZoomCue) {
        model.selectedZoom = cue.id
        model.removeSelectedZoom()
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
            DragGesture(minimumDistance: 1, coordinateSpace: Self.dragSpace)
                .onChanged { value in
                    let origin = resizing ?? {
                        let span = model.editedDisplayRange(of: cue)
                        return ResizeOrigin(
                            id: cue.id,
                            start: span.lowerBound,
                            end: span.upperBound,
                            transition: cue.transitionDuration
                        )
                    }()
                    let delta = value.translation.width / scale
                    withoutAnimation {
                        if resizing == nil {
                            resizing = origin
                            model.selectedZoom = cue.id
                            model.pausePlayback()
                        }
                        model.setZoomRange(
                            cue.id,
                            start: leading ? origin.start + delta : origin.start,
                            end: leading ? origin.end : origin.end + delta,
                            preferredTransition: origin.transition
                        )
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
        DragGesture(minimumDistance: 0, coordinateSpace: Self.dragSpace)
            .onChanged { value in
                let origin = dragging.map(\.start) ?? model.editedDisplayRange(of: cue).lowerBound
                withoutAnimation {
                    if dragging == nil {
                        dragging = (cue.id, origin)
                        model.selectedZoom = cue.id
                    }
                    guard abs(value.translation.width) > 0 else { return }
                    model.moveZoom(cue.id, to: origin + value.translation.width / scale)
                }
            }
            .onEnded { _ in dragging = nil }
    }

    private func clamped(_ time: TimeInterval) -> TimeInterval {
        min(max(time, 0), model.edit.duration)
    }
}
