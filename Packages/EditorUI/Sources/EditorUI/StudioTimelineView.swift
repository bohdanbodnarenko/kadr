import AppKit
import Foundation
import StudioSession
import SwiftUI

/// The clips, the zooms and the playhead, on one ruler (docs/09 U3.3, U3.4).
///
/// One shared time axis rather than a track per kind. A zoom and the cut it sits inside are
/// related by *when* they are, and separate rulers make somebody compare two scales to see
/// a relationship the eye should get for free.
///
/// Zoomable, because fit-to-window is not a working scale. A ten-minute recording across an
/// 800-point timeline is 1.3 points per second — a frame is a fiftieth of a point, so
/// "split here" was a guess and the only way to place a cut accurately was to nudge the
/// playhead with the arrow keys and read the clock. The ruler now stretches to whatever the
/// work needs and scrolls. Pinch and ⌘-scroll pin the time under the pointer; the playhead
/// stays in view while it is moving.
///
/// Clips are edged-trimmed by dragging their ends, the way a trim actually happens in
/// Screendrop: hovering shows a split marker, and **C** splits there without moving the
/// playhead. The preview stays on the playhead until the time bar is dragged. Drag across
/// the zoom lane to place a cue; a click still only scrubs.
///
/// Nothing in this body reads the playhead or the hover time (docs/11 S2). Both move many
/// times a second, and a read here re-evaluated the geometry, the ruler, every clip lane
/// and the zoom lane on each tick. They are read by the leaves that draw them —
/// `StudioTimelinePlayhead`, `PlayheadScrollAnchor`, `PlayheadFollower`, `HoverSplitMarker`
/// — and by closures, which run later and register nothing.
@MainActor
struct StudioTimelineView: View {
    let model: StudioDocumentModel

    /// The height of the clip band. Taller than a label strip so a filmstrip of frames
    /// can sit in it the way a trim actually happens in Screendrop.
    let clipHeight: CGFloat = 44
    let cueHeight: CGFloat = 22
    let rulerHeight: CGFloat = 13
    let handleWidth: CGFloat = 20
    let crownLane = StudioTimelinePlayhead.crownLaneHeight

    /// How many times wider than the window the timeline is drawn. 1 is fit-to-window.
    @State var zoom: CGFloat = 1
    /// Edited time `ScrollViewReader` should keep under `zoomAnchorFraction` of the viewport.
    @State var zoomAnchorTime: TimeInterval = 0
    /// 0…1 horizontal place in the viewport the zoom is pinned to.
    @State var zoomAnchorFraction: CGFloat = 0.5
    /// The cue being dragged, and where it started.
    @State var dragging: (id: ZoomCue.ID, start: TimeInterval)?
    /// A zoom being drawn on the lane, in edited time.
    @State var creating: (start: TimeInterval, end: TimeInterval)?
    /// The clip edge being trimmed, and where it was when the drag began.
    @State var trimOrigin: (id: Clip.ID, edge: TimeInterval)?
    /// Edited time under the pointer, for the split marker and hover-C.
    ///
    /// Read from the model's playhead clock rather than kept in `@State`: a state write on
    /// every mouse move re-rendered this whole view to move one hairline.
    var hoverTime: TimeInterval? {
        model.playheadClock.hoverTime
    }

    /// Latest timeline viewport width, so the zoom buttons can pin around the same axis.
    @State var viewportWidth: CGFloat = 1
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                StudioTimelineTrackHeaders(
                    model: model,
                    topInset: crownLane + rulerHeight + 6,
                    cueHeight: cueHeight,
                    laneSpacing: 6,
                    clipHeight: clipHeight
                )
                timelineBands
            }
            .frame(height: bandsHeight)
            .focusable()
            .focused($isFocused)
            .onAppear { isFocused = true }
            // Simultaneous, not `onTapGesture`: the lane now carries buttons of its own —
            // add-zoom, remove-zoom, accept-suggestion — and a button swallows a plain tap
            // gesture. Clicking one used to take focus away from the timeline and leave C,
            // Z, [, ], the arrows and Delete dead until the user found bare lane to click.
            .simultaneousGesture(TapGesture().onEnded { isFocused = true })
            .onKeyPress("c") {
                if let hoverTime {
                    model.split(at: hoverTime)
                    return .handled
                }
                return .ignored
            }
            // Z adds a zoom where the pointer is (or selects the one already there);
            // [ and ] step between zooms, the way they step between markers elsewhere.
            .onKeyPress("z") {
                model.addOrSelectZoom(at: hoverTime ?? model.playhead)
                return .handled
            }
            .onKeyPress("[") {
                model.selectAdjacentZoom(forward: false)
                return .handled
            }
            .onKeyPress("]") {
                model.selectAdjacentZoom(forward: true)
                return .handled
            }
            .onKeyPress(.leftArrow, phases: .down) { press in
                nudgePlayhead(press, frames: -1)
            }
            .onKeyPress(.rightArrow, phases: .down) { press in
                nudgePlayhead(press, frames: 1)
            }
            .onKeyPress(.return) {
                if let zoom = model.selectedZoom {
                    model.previewZoom(zoom)
                    return .handled
                }
                if model.selectedClip != nil {
                    return .handled
                }
                return .ignored
            }
            .onDeleteCommand {
                if model.selectedZoom != nil {
                    model.removeSelectedZoom()
                } else {
                    model.removeClipAtPlayhead()
                }
            }
            zoomControls(viewportWidth: viewportWidth)
        }
    }

    /// The ruler and the lanes, scrollable and zoomable, beside the fixed track headers.
    private var timelineBands: some View {
        GeometryReader { geometry in
            let viewport = max(geometry.size.width, 1)
            let width = viewport * zoom
            let scale = width / max(model.edit.duration, 0.001)

            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: zoom > 1) {
                    bands(scale: scale, width: width)
                        .overlay(alignment: .topLeading) {
                            PlayheadScrollAnchor(clock: model.playheadClock, scale: scale)
                                .id(Self.playheadAnchor)
                        }
                        .overlay(alignment: .topLeading) {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .offset(x: zoomAnchorTime * scale)
                                .id(Self.zoomAnchor)
                        }
                }
                .background {
                    PlayheadFollower(clock: model.playheadClock, isFollowing: zoom > 1) {
                        scroller.scrollTo(Self.playheadAnchor, anchor: .center)
                    }
                }
                .onChange(of: zoom) {
                    if zoom <= 1 {
                        scroller.scrollTo(Self.zoomAnchor, anchor: .leading)
                    } else {
                        scroller.scrollTo(
                            Self.zoomAnchor,
                            anchor: UnitPoint(x: zoomAnchorFraction, y: 0.5)
                        )
                    }
                }
            }
            .background {
                TimelineZoomCatcher { factor, pointerX in
                    applyZoom(factor: factor, pointerX: pointerX, viewportWidth: viewport)
                }
            }
            .onAppear { viewportWidth = viewport }
            .onChange(of: geometry.size.width) { viewportWidth = max(geometry.size.width, 1) }
        }
    }

    private var bandsHeight: CGFloat {
        // Crown, ruler and the two lanes, plus the VStack spacings between them
        // (3 + 3 + 6). Wrong by a few points and the pin sits on the wrong track.
        crownLane + rulerHeight + cueHeight + clipHeight + 12
    }

    private func bands(scale: CGFloat, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Color.clear
                .frame(width: width, height: crownLane)
            StudioTimelineRuler(
                duration: model.edit.duration,
                width: width,
                scale: scale,
                height: rulerHeight
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.pausePlayback()
                        model.playhead = StudioTimelinePlayhead.time(
                            atX: value.location.x,
                            scale: scale,
                            duration: model.edit.duration
                        )
                    }
            )
            laneStack(scale: scale, width: width)
        }
        .frame(width: width, height: bandsHeight, alignment: .topLeading)
        .coordinateSpace(name: StudioTimelinePlayhead.coordinateSpace)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            hover(phase, scale: scale)
        }
        .overlay(alignment: .topLeading) {
            StudioTimelinePlayhead(
                clock: model.playheadClock,
                scale: scale,
                height: bandsHeight,
                duration: model.edit.duration
            ) { time in
                model.pausePlayback()
                model.playhead = snapEditedTime(time, scale: scale, excludingPlayhead: true)
            }
        }
        .contextMenu {
            Button("Split Clip Here") {
                model.split(at: hoverTime ?? model.playhead)
            }
            Button("Delete Clip", role: .destructive) {
                model.removeClipAtPlayhead()
            }
            .disabled(model.edit.clips.clips.count < 2)
        }
    }

    /// Moves the hover time with the pointer.
    ///
    /// Less than a point of travel is the same place on screen, and every write re-renders
    /// the skim preview, so sub-point moves are dropped.
    private func hover(_ phase: HoverPhase, scale: CGFloat) {
        switch phase {
        case let .active(location):
            let time = StudioTimelinePlayhead.time(
                atX: location.x,
                scale: scale,
                duration: model.edit.duration
            )
            if let current = model.hoverPreviewTime, scale > 0, abs(current - time) * scale < 1 {
                return
            }
            model.hoverPreviewTime = time
        case .ended:
            model.hoverPreviewTime = nil
        }
    }

    private func laneStack(scale: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                StudioZoomLane(
                    model: model,
                    scale: scale,
                    width: width,
                    height: cueHeight,
                    dragging: $dragging,
                    creating: $creating
                )
                clips(scale: scale)
            }
            .contentShape(Rectangle())
            HoverSplitMarker(clock: model.playheadClock, scale: scale, height: cueHeight + clipHeight + 6)
        }
    }

    private static let playheadAnchor = "studio.timeline.playhead"
    private static let zoomAnchor = "studio.timeline.zoom"

    // MARK: - Bands

    private func clips(scale: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(model.edit.clips.clips.enumerated()), id: \.element.id) { index, clip in
                clipLane(clip, index: index, scale: scale)
            }
        }
    }

    private func clipLane(_ clip: Clip, index: Int, scale: CGFloat) -> some View {
        // `currentClipIndex` rather than `clipIndex(at: playhead)`: it changes when the
        // playhead crosses a cut, not on every tick.
        let selected = model.selectedClip == clip.id
            || (model.selectedClip == nil && model.currentClipIndex == index)
        let width = max(clip.editedDuration * scale - 2, 3)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(selected ? 0.55 : 0.28))
            ClipFilmstripLane(
                url: model.session.screenURL,
                clip: clip,
                width: width,
                height: clipHeight
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(0.9)
            if selected {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
            if clip.speed != 1 {
                Text(speedLabel(clip.speed))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.leading, 10)
            }
            HStack(spacing: 0) {
                handle(isLeading: true, clip: clip, index: index, scale: scale)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                model.selectedClip = clip.id
                                model.selectedZoom = nil
                                model.pausePlayback()
                                let start = model.editedStart(ofClipAt: index)
                                model.playhead = start + (handleWidth + value.location.x) / scale
                            }
                    )
                handle(isLeading: false, clip: clip, index: index, scale: scale)
            }
        }
        .frame(width: width, height: clipHeight)
        .help("Drag the ends to trim. Hover and press C to split.")
    }

    // MARK: - Formatting

    static func tickInterval(forDuration duration: TimeInterval, width: CGFloat) -> TimeInterval {
        guard duration > 0, width > 0 else { return 0 }
        let minimumSpacing: CGFloat = 56
        let smallest = duration * Double(minimumSpacing / width)
        let candidates: [TimeInterval] = [
            0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600
        ]
        return candidates.first { $0 >= smallest } ?? candidates[candidates.count - 1]
    }

    static func tickLabel(_ seconds: TimeInterval, step: TimeInterval = 1) -> String {
        let minutes = Int(seconds) / 60
        if step < 1 {
            let remainder = seconds - Double(minutes * 60)
            return String(format: "%d:%04.1f", minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, Int(seconds.rounded()) % 60)
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded()
            ? "\(Int(speed))×"
            : String(format: "%.1f×", speed)
    }
}

/// The ruler, as its own view so it re-renders only when its inputs change.
///
/// Every field is a plain value, so SwiftUI compares them and skips the body — the tick
/// `ForEach` — when the duration, width and scale are what they were.
struct StudioTimelineRuler: View {
    let duration: TimeInterval
    let width: CGFloat
    let scale: CGFloat
    let height: CGFloat

    var body: some View {
        let step = StudioTimelineView.tickInterval(forDuration: duration, width: width)
        let count = step > 0 ? Int(duration / step) : 0
        ZStack(alignment: .topLeading) {
            ForEach(0 ... max(count, 0), id: \.self) { index in
                let time = Double(index) * step
                if time <= duration {
                    HStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 1, height: 4)
                        Text(StudioTimelineView.tickLabel(time, step: step))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .offset(x: time * scale)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
    }
}

/// The invisible marker `ScrollViewReader` scrolls to, moved with the playhead.
private struct PlayheadScrollAnchor: View {
    let clock: StudioPlayhead
    let scale: CGFloat

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .offset(x: clock.time * scale)
    }
}

/// Keeps a zoomed timeline scrolled to the playhead while it moves.
///
/// A leaf so the per-tick `onChange` lives in a body that has nothing else to rebuild.
private struct PlayheadFollower: View {
    let clock: StudioPlayhead
    let isFollowing: Bool
    let follow: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: clock.time) {
                guard isFollowing else { return }
                follow()
            }
    }
}

/// The hairline under the pointer that shows where hover-C would split.
private struct HoverSplitMarker: View {
    let clock: StudioPlayhead
    let scale: CGFloat
    let height: CGFloat

    var body: some View {
        if let time = clock.hoverTime {
            Rectangle()
                .fill(Color.primary.opacity(0.28))
                .frame(width: 1, height: height)
                .offset(x: time * scale)
                .allowsHitTesting(false)
        }
    }
}
