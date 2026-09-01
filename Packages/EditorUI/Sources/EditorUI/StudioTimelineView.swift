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
/// work needs and scrolls, with the playhead kept in view.
@MainActor
struct StudioTimelineView: View {
    let model: StudioDocumentModel

    /// The height of the clip band. The cue band sits above it, shorter, because cues are
    /// secondary to the cuts — a zoom over nothing is meaningless, a cut without one is not.
    private let clipHeight: CGFloat = 34
    private let cueHeight: CGFloat = 18
    private let rulerHeight: CGFloat = 13

    /// How many times wider than the window the timeline is drawn. 1 is fit-to-window.
    @State private var zoom: CGFloat = 1
    /// The cue being dragged, and where it started.
    ///
    /// Held rather than mutated in place so the drag reads as one edit: every tick applies
    /// the whole offset to the *original* start, which is also what makes it coalesce into a
    /// single undo step instead of forty.
    @State private var dragging: (id: ZoomCue.ID, start: TimeInterval)?

    /// The most a timeline may be stretched.
    ///
    /// Sixty puts a ten-minute recording at about 80 points a second, which is a frame every
    /// point and a half at 60 fps — past that the ruler is wider than any reason to scroll it.
    private static let maximumZoom: CGFloat = 60

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let viewport = max(geometry.size.width, 1)
                let width = viewport * zoom
                let scale = width / max(model.edit.duration, 0.001)

                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: zoom > 1) {
                        bands(scale: scale, width: width)
                            // An anchor the scroller can bring into view, moved to wherever
                            // the playhead is. Without it, playing a zoomed-in timeline runs
                            // the playhead off the right-hand edge and leaves the user
                            // watching a stationary picture of the past.
                            .overlay(alignment: .topLeading) {
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .offset(x: model.playhead * scale)
                                    .id(Self.playheadAnchor)
                            }
                    }
                    .onChange(of: model.playhead) {
                        guard zoom > 1 else { return }
                        scroller.scrollTo(Self.playheadAnchor, anchor: .center)
                    }
                }
            }
            .frame(height: rulerHeight + cueHeight + clipHeight + 9)
            zoomControls
        }
    }

    private func bands(scale: CGFloat, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ruler(scale: scale, width: width)
            ZStack(alignment: .topLeading) {
                // The scrub target is the bands themselves, so a press that lands on a cue
                // selects the cue and does not also fling the playhead across the recording
                // — which is what a drag gesture over the whole stack did.
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear.frame(height: cueHeight)
                    clips(scale: scale)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { model.playhead = $0.location.x / scale }
                )
                cues(scale: scale)
                playhead(scale: scale, height: cueHeight + clipHeight + 6)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    private static let playheadAnchor = "studio.timeline.playhead"

    // MARK: - Zoom

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Spacer()
            Button {
                setZoom(zoom / 2)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoom <= 1)
            .help("Show more of the recording")

            Button("Fit") { setZoom(1) }
                .disabled(zoom == 1)
                .help("Fit the whole recording")

            Button {
                setZoom(zoom * 2)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(zoom >= Self.maximumZoom)
            .help("Stretch the timeline for a closer cut")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
    }

    private func setZoom(_ proposed: CGFloat) {
        zoom = min(max(proposed, 1), Self.maximumZoom)
    }

    // MARK: - Bands

    /// Time labels at a round interval, chosen so they never collide.
    ///
    /// Without these the timeline is a featureless bar: a ten-minute recording and a
    /// ten-second one look identical, and "where in the recording am I" has to be read off a
    /// number somewhere else entirely.
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
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(model.clipIndex(at: model.playhead) == index ? 0.55 : 0.3))
                    // Three points, not one: a clip trimmed to a few frames used to collapse
                    // into a hairline nobody could see, on a timeline whose whole job is to
                    // show what the edit is made of.
                    .frame(width: max(clip.editedDuration * scale - 2, 3), height: clipHeight)
                    .overlay(alignment: .leading) {
                        if clip.speed != 1 {
                            Text(speedLabel(clip.speed))
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 4)
                        }
                    }
            }
        }
    }

    /// The zoom cues, draggable along the timeline.
    ///
    /// Dragging is the fix for the studio's oddest gap: a cue's start could not be changed
    /// at all. `addZoom` dropped it at the playhead and the inspector offered magnification,
    /// hold and move — so putting a zoom half a second earlier meant deleting it, moving the
    /// playhead and adding it again, which loses everything else about it.
    private func cues(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.edit.zooms) { cue in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.orange.opacity(model.selectedZoom == cue.id ? 0.9 : 0.5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.primary.opacity(dragging?.id == cue.id ? 0.7 : 0), lineWidth: 1)
                    }
                    .frame(width: max((cue.end - cue.start) * scale, 6), height: cueHeight)
                    .offset(x: cue.start * scale)
                    .help("\(String(format: "%.1f", cue.magnification))× zoom — drag to move it")
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                model.selectedZoom = cue.id
                                let origin = dragging.map(\.start) ?? cue.start
                                if dragging == nil {
                                    dragging = (cue.id, cue.start)
                                }
                                model.moveZoom(cue.id, to: origin + value.translation.width / scale)
                            }
                            .onEnded { _ in dragging = nil }
                    )
            }
        }
        .frame(height: cueHeight, alignment: .topLeading)
    }

    private func playhead(scale: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 1.5, height: height)
            .offset(x: model.playhead * scale)
            .allowsHitTesting(false)
    }

    // MARK: - Formatting

    /// A round number of seconds that leaves the labels at least 56 points apart.
    ///
    /// Picked from the recording's length *and the drawn width*, so stretching the timeline
    /// gives finer ticks rather than the same five labels further apart.
    static func tickInterval(forDuration duration: TimeInterval, width: CGFloat) -> TimeInterval {
        guard duration > 0, width > 0 else { return 0 }
        let minimumSpacing: CGFloat = 56
        let smallest = duration * Double(minimumSpacing / width)
        let candidates: [TimeInterval] = [
            0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600
        ]
        return candidates.first { $0 >= smallest } ?? candidates[candidates.count - 1]
    }

    /// Minutes and seconds, with tenths once the ruler is fine enough to show them.
    static func tickLabel(_ seconds: TimeInterval, step: TimeInterval = 1) -> String {
        let minutes = Int(seconds) / 60
        if step < 1 {
            let remainder = seconds - Double(minutes * 60)
            return String(format: "%d:%04.1f", minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, Int(seconds.rounded()) % 60)
    }

    /// `2×` rather than `2.0×`: a speed is chosen from a small set and the extra digit is
    /// noise on a label this size.
    private func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded()
            ? "\(Int(speed))×"
            : String(format: "%.1f×", speed)
    }
}
