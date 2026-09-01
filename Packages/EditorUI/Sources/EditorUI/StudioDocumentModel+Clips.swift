import Foundation
import StudioSession

/// Cutting, trimming and retiming the recording (docs/09 U3.4, docs/08 §2 item 12).
///
/// Its own file because these are the four operations that change *how long the video is*,
/// and everything else in the studio is about how it looks. They also share one rule worth
/// stating once: the playhead has to end up somewhere the user expects, because a cut that
/// leaves it pointing at footage that no longer exists reads as the edit having gone wrong.
@MainActor
public extension StudioDocumentModel {
    // MARK: - Clips

    /// Splits the clip under the playhead.
    func splitAtPlayhead() {
        split(at: playhead)
    }

    /// Splits at an edited-time instant, which may not be the playhead — hover-C on the
    /// timeline cuts where the pointer is, not where the clock is.
    func split(at time: TimeInterval) {
        change { $0.clips.split(atEdited: time) }
    }

    /// Whether this recording has a notch strip that could be trimmed (docs/08 §2 item 12).
    ///
    /// Only for a recording that has not already been cropped: a second press would take
    /// another strip off whatever the first one left, and "remove the notch" is a thing you
    /// do once.
    var canTrimNotch: Bool {
        manifest.topInset > 0 && edit.cropRect == nil
    }

    /// Crops away the strip beside the notch.
    ///
    /// A full-screen recording on a notched MacBook includes the menu-bar strip with the
    /// notch cut out of it, and no amount of framing hides that the video has a bite taken
    /// out of the top. Screendrop removes it; this is the same idea, using the height the
    /// display itself reported when the recording was made rather than a guessed menu-bar
    /// height — which is wrong on exactly the Macs that have a notch.
    func trimNotchStrip() {
        let height = manifest.pixelSize.height
        guard manifest.topInset > 0, height > 0 else { return }
        let fraction = min(manifest.topInset / height, 0.5)
        change {
            $0.cropRect = CGRect(x: 0, y: fraction, width: 1, height: 1 - fraction)
        }
    }

    /// Drops everything before the playhead (docs/08 §2 item 12).
    ///
    /// The playhead moves to the new start, because the frame the user was looking at when
    /// they trimmed is the frame the recording now opens on — leaving the playhead where it
    /// was would jump them somewhere they did not choose.
    func trimStartToPlayhead() {
        guard playhead > 0, playhead < edit.duration else { return }
        change { $0.clips.trimStart(toEdited: playhead) }
        playhead = 0
    }

    /// Drops everything after the playhead.
    func trimEndToPlayhead() {
        guard playhead > 0, playhead < edit.duration else { return }
        change { $0.clips.trimEnd(toEdited: playhead) }
        playhead = edit.duration
    }

    /// Removes the clip the playhead is in, if it is not the last one.
    ///
    /// The last clip stays: a timeline with nothing in it is not an edit, it is a deleted
    /// recording, and deleting a recording is not something a trim button should do.
    func removeClipAtPlayhead() {
        let clips = edit.clips.clips
        guard clips.count > 1 else {
            failure = "This is the only clip left. Delete the recording itself if that is what you meant."
            return
        }
        guard let index = clipIndex(at: playhead) else { return }
        change {
            var remaining = $0.clips.clips
            remaining.remove(at: index)
            $0.clips = ClipTimeline(clips: remaining)
        }
        playhead = min(playhead, edit.duration)
    }

    /// Puts the recording back to one uncut clip at real speed.
    ///
    /// The escape hatch after a session of splits, trims and retimes that went too far.
    /// Footage is never deleted, so this is always possible.
    func resetClips() {
        change { $0.clips = .whole(duration: manifest.duration) }
        selectedClip = nil
        playhead = min(playhead, edit.duration)
    }

    /// True once a split, trim or speed change has left the original recording.
    var hasClipEdits: Bool {
        let clips = edit.clips.clips
        guard clips.count == 1, let clip = clips.first else { return true }
        return clip.speed != 1 || abs(clip.editedDuration - manifest.duration) > 0.001
    }

    /// Deletes the selected zoom, or the clip under the playhead.
    ///
    /// One trash control, the way the timeline's delete key already works: a selected zoom
    /// is the thing being aimed at, so it goes first.
    func deleteTimelineSelection() {
        if selectedZoom != nil {
            removeSelectedZoom()
        } else {
            removeClipAtPlayhead()
        }
    }

    var canDeleteTimelineSelection: Bool {
        selectedZoom != nil || edit.clips.clips.count > 1
    }

    /// Sets the speed of the clip under the playhead.
    func setSpeedAtPlayhead(_ speed: Double) {
        guard let index = clipIndex(at: playhead) else { return }
        let id = edit.clips.clips[index].id
        change { $0.clips.setSpeed(speed, for: id) }
        playhead = min(playhead, edit.duration)
    }

    /// Shortens a clip from the left, coalesced so one drag is one undo step.
    func trimClipStart(_ id: Clip.ID, toEdited time: TimeInterval) {
        guard let index = edit.clips.clips.firstIndex(where: { $0.id == id }) else { return }
        change(coalescingAs: "clip.trim.start.\(id)") {
            $0.clips.trimClipStart(at: index, toEdited: time)
        }
        playhead = min(playhead, edit.duration)
    }

    /// Shortens a clip from the right.
    func trimClipEnd(_ id: Clip.ID, toEdited time: TimeInterval) {
        guard let index = edit.clips.clips.firstIndex(where: { $0.id == id }) else { return }
        change(coalescingAs: "clip.trim.end.\(id)") {
            $0.clips.trimClipEnd(at: index, toEdited: time)
        }
        playhead = min(playhead, edit.duration)
    }

    /// Sets the speed of a clip by id, so the inspector can retime a selection that is not
    /// under the playhead.
    func setSpeed(_ speed: Double, for id: Clip.ID) {
        change(coalescingAs: "clip.speed.\(id)") { $0.clips.setSpeed(speed, for: id) }
        playhead = min(playhead, edit.duration)
    }

    /// Which clip contains an edited-time instant.
    func clipIndex(at time: TimeInterval) -> Int? {
        var elapsed: TimeInterval = 0
        for (index, clip) in edit.clips.clips.enumerated() {
            let next = elapsed + clip.editedDuration
            if time < next || index == edit.clips.clips.count - 1 {
                return index
            }
            elapsed = next
        }
        return nil
    }
}
