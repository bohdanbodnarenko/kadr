import AppKit
import StudioSession
import SwiftUI

extension StudioTimelineView {
    func handle(isLeading: Bool, clip: Clip, index: Int, scale: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.85))
                .frame(width: 3, height: clipHeight - 12)
        }
        .frame(width: handleWidth, height: clipHeight)
        .contentShape(Rectangle())
        .accessibilityLabel(isLeading ? "Trim clip start" : "Trim clip end")
        // Adjustable rather than a button with no action (docs/17 T-STU-11): each step
        // moves the edge one frame.
        .accessibilityAdjustableAction { direction in
            let frame = 1.0 / Double(max(model.manifest.frameRate, 1))
            let delta = direction == .increment ? frame : -frame
            let edge = model.editedStart(ofClipAt: index) + (isLeading ? 0 : clip.editedDuration)
            if isLeading {
                model.trimClipStart(clip.id, toEdited: edge + delta)
            } else {
                model.trimClipEnd(clip.id, toEdited: edge + delta)
            }
        }
        // Measured from where the edge was when the drag began, in the timeline's own
        // space. Adding the whole translation to the edge's *current* position compounded
        // every event — the edge ran ahead of the pointer — and the handle's local space
        // moves with the clip it is trimming.
        .gesture(
            DragGesture(
                minimumDistance: 1,
                coordinateSpace: .named(StudioTimelinePlayhead.coordinateSpace)
            )
            .onChanged { value in
                let origin = trimOrigin?.id == clip.id
                    ? trimOrigin?.edge ?? 0
                    : model.editedStart(ofClipAt: index) + (isLeading ? 0 : clip.editedDuration)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if trimOrigin?.id != clip.id {
                        trimOrigin = (clip.id, origin)
                        model.selectedClip = clip.id
                        model.pausePlayback()
                    }
                    let raw = origin + value.translation.width / scale
                    // The edge being dragged is not a snap target: snapping it to itself
                    // made it stick wherever it was.
                    let live = model.edit.clips.clips.indices.contains(index)
                        ? model.editedStart(ofClipAt: index)
                        + (isLeading ? 0 : model.edit.clips.clips[index].editedDuration)
                        : origin
                    let time = snapEditedTime(raw, scale: scale, ignoring: [origin, live])
                    if isLeading {
                        model.trimClipStart(clip.id, toEdited: time)
                    } else {
                        model.trimClipEnd(clip.id, toEdited: time)
                    }
                }
            }
            .onEnded { _ in
                trimOrigin = nil
                AlignmentHaptic.released()
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

    func nudgePlayhead(_ press: KeyPress, frames: Int) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        let option = press.modifiers.contains(.option)
        if shift, let index = model.selectedClip.flatMap({ id in
            model.edit.clips.clips.firstIndex(where: { $0.id == id })
        }) ?? model.currentClipIndex {
            // Symmetric, and in the recording's own frames (docs/17 T-STU-11): ⇧← and ⇧→
            // move whichever edge of the clip is nearer the playhead one frame left or
            // right. They used to trim the start from ← and the end from →, by 1/30 s
            // whatever the frame rate.
            let clip = model.edit.clips.clips[index]
            let start = model.editedStart(ofClipAt: index)
            let end = start + clip.editedDuration
            let frame = 1.0 / Double(max(model.manifest.frameRate, 1))
            let delta = Double(frames) * (option ? 1.0 : frame)
            if abs(model.playhead - start) <= abs(end - model.playhead) {
                model.trimClipStart(clip.id, toEdited: start + delta)
            } else {
                model.trimClipEnd(clip.id, toEdited: end + delta)
            }
            return .handled
        }
        if option {
            model.step(seconds: Double(frames) * 5)
        } else {
            model.step(frames: frames)
        }
        return .handled
    }

    /// - Parameter ignored: the edge being dragged — where it started and where it is —
    ///   which must not snap to itself.
    func snapEditedTime(
        _ time: TimeInterval,
        scale: CGFloat,
        excludingPlayhead: Bool = false,
        ignoring ignored: [TimeInterval] = []
    ) -> TimeInterval {
        var candidates: [TimeInterval] = [0, model.edit.duration]
        if !excludingPlayhead {
            candidates.append(model.playhead)
        }
        // Every clip boundary, from the model's cached ends: once for the start of the
        // edit and once per clip end. The loop it replaced summed a prefix per clip.
        candidates.append(contentsOf: model.clipEnds)
        // Zooms in edited time, like everything else here: `start` and `end` are source
        // time, and after a cut they point at the wrong place on this ruler.
        for cue in model.edit.zooms {
            let range = model.editedDisplayRange(of: cue)
            candidates.append(range.lowerBound)
            candidates.append(range.upperBound)
        }
        candidates.removeAll { candidate in
            ignored.contains { abs($0 - candidate) < 0.0005 }
        }
        let snapped = TimelineSnap.snap(
            time,
            candidates: candidates,
            scale: scale,
            bypassed: NSEvent.modifierFlags.contains(.command)
        )
        if snapped != time {
            AlignmentHaptic.snap(id: String(format: "%.3f", snapped))
        }
        return snapped
    }
}
