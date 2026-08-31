import Foundation
import StudioSession
import SwiftUI

/// The clips, the zooms and the playhead, on one ruler (docs/09 U3.3, U3.4).
///
/// One shared time axis rather than a track per kind. A zoom and the cut it sits inside are
/// related by *when* they are, and separate rulers make somebody compare two scales to see
/// a relationship the eye should get for free.
@MainActor
struct StudioTimelineView: View {
    let model: StudioDocumentModel

    /// The height of the clip band. The cue band sits above it, shorter, because cues are
    /// secondary to the cuts — a zoom over nothing is meaningless, a cut without one is not.
    private let clipHeight: CGFloat = 34
    private let cueHeight: CGFloat = 18
    private let rulerHeight: CGFloat = 13

    /// The cue being dragged, and what it looked like when the drag began.
    ///
    /// Held rather than mutated in place so the drag reads as one edit: every tick applies
    /// the whole offset to the *original* start, which is also what makes it coalesce into a
    /// single undo step instead of forty.
    @State private var dragging: (id: ZoomCue.ID, start: TimeInterval)?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let scale = width / max(model.edit.duration, 0.001)

            VStack(alignment: .leading, spacing: 3) {
                ruler(scale: scale, width: width)
                ZStack(alignment: .topLeading) {
                    // The scrub target is the bands themselves, so a press that lands on a
                    // cue selects the cue and does not also fling the playhead across the
                    // recording — which is what a drag gesture over the whole stack did.
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
        .frame(height: rulerHeight + cueHeight + clipHeight + 9)
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
                        Text(Self.tickLabel(time))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .offset(x: time * scale)
                }
            }
        }
        .frame(height: rulerHeight, alignment: .topLeading)
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
    /// Picked from the recording's length rather than fixed, because the same timeline has
    /// to read sensibly for a twenty-second clip and an hour-long one.
    static func tickInterval(forDuration duration: TimeInterval, width: CGFloat) -> TimeInterval {
        guard duration > 0, width > 0 else { return 0 }
        let minimumSpacing: CGFloat = 56
        let smallest = duration * Double(minimumSpacing / width)
        let candidates: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        return candidates.first { $0 >= smallest } ?? candidates[candidates.count - 1]
    }

    static func tickLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `2×` rather than `2.0×`: a speed is chosen from a small set and the extra digit is
    /// noise on a label this size.
    private func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded()
            ? "\(Int(speed))×"
            : String(format: "%.1f×", speed)
    }
}
