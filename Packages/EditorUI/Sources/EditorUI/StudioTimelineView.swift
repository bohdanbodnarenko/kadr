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
/// Screendrop: hovering shows a skim line, and **C** splits there without moving the playhead.
/// Drag across the zoom lane to place a cue; a click still only scrubs.
@MainActor
struct StudioTimelineView: View {
    let model: StudioDocumentModel

    /// The height of the clip band. Taller than a label strip so a filmstrip of frames
    /// can sit in it the way a trim actually happens in Screendrop.
    private let clipHeight: CGFloat = 44
    private let cueHeight: CGFloat = 22
    private let rulerHeight: CGFloat = 13
    private let handleWidth: CGFloat = 8
    private let crownLane = StudioTimelinePlayhead.crownLaneHeight

    /// How many times wider than the window the timeline is drawn. 1 is fit-to-window.
    @State private var zoom: CGFloat = 1
    /// Edited time `ScrollViewReader` should keep under `zoomAnchorFraction` of the viewport.
    @State private var zoomAnchorTime: TimeInterval = 0
    /// 0…1 horizontal place in the viewport the zoom is pinned to.
    @State private var zoomAnchorFraction: CGFloat = 0.5
    /// The cue being dragged, and where it started.
    @State private var dragging: (id: ZoomCue.ID, start: TimeInterval)?
    /// A zoom being drawn on the lane, in edited time.
    @State private var creating: (start: TimeInterval, end: TimeInterval)?
    /// Edited time under the pointer, for skim and hover-C.
    @State private var hoverTime: TimeInterval?
    /// Latest timeline viewport width, so the zoom buttons can pin around the same axis.
    @State private var viewportWidth: CGFloat = 1
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let viewport = max(geometry.size.width, 1)
                let width = viewport * zoom
                let scale = width / max(model.edit.duration, 0.001)

                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: zoom > 1) {
                        bands(scale: scale, width: width)
                            .overlay(alignment: .topLeading) {
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .offset(x: model.playhead * scale)
                                    .id(Self.playheadAnchor)
                            }
                            .overlay(alignment: .topLeading) {
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .offset(x: zoomAnchorTime * scale)
                                    .id(Self.zoomAnchor)
                            }
                    }
                    .onChange(of: model.playhead) {
                        guard zoom > 1 else { return }
                        scroller.scrollTo(Self.playheadAnchor, anchor: .center)
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
            .frame(height: bandsHeight)
            .focusable()
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onTapGesture { isFocused = true }
            .onKeyPress("c") {
                if let hoverTime {
                    model.split(at: hoverTime)
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

    private var bandsHeight: CGFloat {
        // Crown, ruler and the two lanes, plus the VStack spacings between them
        // (3 + 3 + 6). Wrong by a few points and the pin sits on the wrong track.
        crownLane + rulerHeight + cueHeight + clipHeight + 12
    }

    private func bands(scale: CGFloat, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Color.clear
                .frame(width: width, height: crownLane)
            ruler(scale: scale, width: width)
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
            switch phase {
            case let .active(location):
                hoverTime = StudioTimelinePlayhead.time(
                    atX: location.x,
                    scale: scale,
                    duration: model.edit.duration
                )
                model.skimTime = hoverTime
            case .ended:
                hoverTime = nil
                model.skimTime = nil
            }
        }
        .overlay(alignment: .topLeading) {
            StudioTimelinePlayhead(
                time: model.playhead,
                scale: scale,
                height: bandsHeight,
                duration: model.edit.duration
            ) { time in
                model.pausePlayback()
                model.playhead = time
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
            if let hoverTime {
                Rectangle()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: 1, height: cueHeight + clipHeight + 6)
                    .offset(x: hoverTime * scale)
                    .allowsHitTesting(false)
            }
        }
    }

    private static let playheadAnchor = "studio.timeline.playhead"
    private static let zoomAnchor = "studio.timeline.zoom"

    // MARK: - Zoom

    private func zoomControls(viewportWidth: CGFloat) -> some View {
        HStack(spacing: 2) {
            zoomIcon("minus.magnifyingglass", help: "Show more of the recording (⌘-)") {
                applyZoom(factor: 1 / StudioTimelineZoom.step, pointerX: nil, viewportWidth: viewportWidth)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= 1.0001)

            zoomIcon("plus.magnifyingglass", help: "Stretch the timeline for a closer cut (⌘=)") {
                applyZoom(factor: StudioTimelineZoom.step, pointerX: nil, viewportWidth: viewportWidth)
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(zoom >= StudioTimelineZoom.maximum - 0.0001)

            zoomIcon("arrow.left.and.right", help: "Fit the whole recording (⌘0)") {
                applyZoom(factor: 1 / max(zoom, 1), pointerX: nil, viewportWidth: viewportWidth)
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(zoom <= 1.0001)

            if zoom > 1.0001 {
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            Spacer(minLength: 0)
        }
    }

    private func zoomIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// Stretches around the pointer when we know it, otherwise around the hovered time or
    /// the playhead — so pinch / ⌘-scroll / ⌘= do not shove the cut off the screen.
    private func applyZoom(factor: CGFloat, pointerX: CGFloat?, viewportWidth: CGFloat) {
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

    // MARK: - Bands

    private func ruler(scale: CGFloat, width: CGFloat) -> some View {
        let step = Self.tickInterval(forDuration: model.edit.duration, width: width)
        let count = step > 0 ? Int(model.edit.duration / step) : 0
        return ZStack(alignment: .topLeading) {
            ForEach(0 ... max(count, 0), id: \.self) { index in
                let time = Double(index) * step
                if time <= model.edit.duration {
                    HStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 1, height: 4)
                        Text(Self.tickLabel(time, step: step))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .offset(x: time * scale)
                }
            }
        }
        .frame(width: width, height: rulerHeight, alignment: .topLeading)
        .clipped()
    }

    private func clips(scale: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(model.edit.clips.clips.enumerated()), id: \.element.id) { index, clip in
                clipLane(clip, index: index, scale: scale)
            }
        }
    }

    private func clipLane(_ clip: Clip, index: Int, scale: CGFloat) -> some View {
        let selected = model.selectedClip == clip.id
            || (model.selectedClip == nil && model.clipIndex(at: model.playhead) == index)
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
                    .font(.caption2.monospacedDigit().weight(.semibold))
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
                                let start = model.edit.clips.editedStartTime(ofClipAt: index)
                                model.playhead = start + (handleWidth + value.location.x) / scale
                            }
                    )
                handle(isLeading: false, clip: clip, index: index, scale: scale)
            }
        }
        .frame(width: width, height: clipHeight)
        .help("Drag the ends to trim. Hover and press C to split.")
    }

    private func handle(isLeading: Bool, clip: Clip, index: Int, scale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.85))
            .frame(width: 3, height: clipHeight - 12)
            .padding(.horizontal, 3)
            .frame(width: handleWidth, height: clipHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        model.selectedClip = clip.id
                        model.pausePlayback()
                        let start = model.edit.clips.editedStartTime(ofClipAt: index)
                        let time = start + (isLeading ? 0 : clip.editedDuration) + value.translation.width / scale
                        if isLeading {
                            model.trimClipStart(clip.id, toEdited: time)
                        } else {
                            model.trimClipEnd(clip.id, toEdited: time)
                        }
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
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

/// Frames of one clip, decoded lazily as the lane's width changes.
private struct ClipFilmstripLane: View {
    let url: URL
    let clip: Clip
    let width: CGFloat
    let height: CGFloat

    @State private var images: [CGImage] = []

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: tileWidth, height: height)
                    .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
        .allowsHitTesting(false)
        .task(id: loadKey) {
            let count = StudioFilmstrip.tileCount(forWidth: width)
            let times = StudioFilmstrip.sampleTimes(
                start: clip.sourceStart,
                duration: clip.sourceDuration,
                count: count
            )
            images = await StudioFilmstrip.images(from: url, times: times)
        }
    }

    private var tileWidth: CGFloat {
        max(width / CGFloat(max(images.count, 1)), 1)
    }

    private var loadKey: String {
        "\(clip.id.uuidString)-\(clip.sourceStart)-\(clip.sourceDuration)-\(Int(width))"
    }
}
