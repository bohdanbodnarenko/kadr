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
        .accessibilityAddTraits(.isButton)
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

    func nudgePlayhead(_ press: KeyPress, frames: Int) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        let option = press.modifiers.contains(.option)
        if shift, let index = model.selectedClip.flatMap({ id in
            model.edit.clips.clips.firstIndex(where: { $0.id == id })
        }) ?? model.clipIndex(at: model.playhead) {
            let clip = model.edit.clips.clips[index]
            let start = model.edit.clips.editedStartTime(ofClipAt: index)
            let step = option ? 1.0 : (1.0 / 30.0)
            let delta = Double(frames) * step
            if frames < 0 {
                model.trimClipStart(clip.id, toEdited: model.playhead + delta)
            } else {
                model.trimClipEnd(clip.id, toEdited: start + clip.editedDuration + delta)
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
}
