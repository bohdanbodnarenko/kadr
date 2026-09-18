import Foundation
import StudioSession

/// Zooms the recording suggests, one at a time (docs/09 U3.3).
///
/// "Smart zooms" used to be the only way to use the click telemetry, and it replaced every
/// zoom on the lane — including the ones placed by hand. The planner's cues are now shown
/// on the lane as suggestions wherever nothing is zoomed yet: click one to keep it, dismiss
/// the ones that are wrong, or add every remaining one without disturbing the rest.
@MainActor
public extension StudioDocumentModel {
    /// Suggestions that do not overlap a zoom already on the lane and were not dismissed.
    var zoomSuggestions: [ZoomCue] {
        guard showsZoomSuggestions else { return [] }
        let taken = edit.zooms.map { editedDisplayRange(of: $0) }
        return plannedZooms.filter { cue in
            guard !dismissedZoomSuggestions.contains(Self.suggestionKey(cue)) else { return false }
            let range = editedDisplayRange(of: cue)
            return !taken.contains { $0.overlaps(range) }
        }
    }

    /// Keeps one suggestion as a real zoom, and selects it.
    func acceptZoomSuggestion(_ suggestion: ZoomCue) {
        var cue = suggestion
        cue.id = UUID()
        change(named: "Add Zoom") { $0.zooms.append(cue) }
        selectedZoom = cue.id
        selectedClip = nil
    }

    /// Hides one suggestion for the rest of this session.
    func dismissZoomSuggestion(_ suggestion: ZoomCue) {
        dismissedZoomSuggestions.insert(Self.suggestionKey(suggestion))
    }

    /// Adds every suggestion still showing. Zooms already on the lane are kept.
    func addSuggestedZooms() {
        let accepted = zoomSuggestions.map { cue -> ZoomCue in
            var copy = cue
            copy.id = UUID()
            return copy
        }
        guard !accepted.isEmpty else {
            if plannedZooms.isEmpty {
                failure = .noClickClusters()
            }
            return
        }
        change(named: "Add Suggested Zooms") { $0.zooms.append(contentsOf: accepted) }
        selectedZoom = nil
    }

    /// Brings back every dismissed suggestion.
    func restoreDismissedZoomSuggestions() {
        dismissedZoomSuggestions = []
    }

    /// Where a zoom added at `time` would sit: the default length from there, stopped by
    /// the zooms either side and the end of the recording. Nil when there is no room —
    /// `time` is inside a zoom, or the gap is too small to hold one.
    ///
    /// The same answer the lane's hover preview draws and a click adds, so what is shown is
    /// exactly what appears.
    func zoomPlacement(at time: TimeInterval) -> (low: TimeInterval, high: TimeInterval)? {
        let footprint = Self.defaultZoomHold + Self.defaultTransition * 2
        let start = min(max(time, 0), max(edit.duration - footprint, 0))
        let origin = edit.zooms.contains { editedDisplayRange(of: $0).contains(time) } ? time : start
        let span = proposedZoomSpan(origin: origin, current: origin + footprint)
        guard span.high - span.low >= Self.minimumPlacedZoom else { return nil }
        return span
    }

    /// How long a zoom added with one click holds.
    static let defaultZoomHold: TimeInterval = 3
    /// The shortest gap a one-click zoom will fill.
    static let minimumPlacedZoom: TimeInterval = 1

    /// A click on the lane, the Z key and the + buttons: select the zoom already covering
    /// `time`, or add one that fits there.
    func addOrSelectZoom(at time: TimeInterval) {
        if let existing = edit.zooms.first(where: { editedDisplayRange(of: $0).contains(time) }) {
            selectedZoom = existing.id
            selectedClip = nil
            return
        }
        if let span = zoomPlacement(at: time) {
            addZoom(from: span.low, to: span.high)
        } else {
            notice = "There is no room for a zoom there. Drag a zoom's edges to make space."
        }
    }

    // MARK: - Moving between zooms

    /// The zooms in the order they play, for "2 of 5" and for stepping.
    var zoomsInOrder: [ZoomCue] {
        edit.zooms.sorted { editedDisplayRange(of: $0).lowerBound < editedDisplayRange(of: $1).lowerBound }
    }

    /// Selects the next (or previous) zoom and puts the playhead on it.
    ///
    /// Counted from the selected zoom when there is one — the inspector's arrows are about
    /// "the one I am looking at" — and from the playhead otherwise.
    func selectAdjacentZoom(forward: Bool) {
        let ordered = zoomsInOrder
        let target: ZoomCue?
        if let selectedZoom, let index = ordered.firstIndex(where: { $0.id == selectedZoom }) {
            let next = forward ? index + 1 : index - 1
            target = ordered.indices.contains(next) ? ordered[next] : nil
        } else {
            let current = playhead
            target = forward
                ? ordered.first { editedDisplayRange(of: $0).lowerBound > current + 0.01 }
                : ordered.last { editedDisplayRange(of: $0).lowerBound < current - 0.01 }
        }
        guard let target else { return }
        pausePlayback()
        selectedZoom = target.id
        selectedClip = nil
        playhead = editedDisplayRange(of: target).lowerBound
    }

    /// Plays a zoom from a moment before it, so the move in can be judged.
    func previewZoom(_ id: ZoomCue.ID) {
        guard let cue = edit.zooms.first(where: { $0.id == id }) else { return }
        pausePlayback()
        selectedZoom = id
        playhead = max(editedDisplayRange(of: cue).lowerBound - Self.previewLeadIn, 0)
        play()
    }

    /// How much of the recording plays before a previewed zoom starts moving.
    static let previewLeadIn: TimeInterval = 0.5

    /// How many recorded clicks fall inside a cue, for the suggestion's label.
    func clickCount(in cue: ZoomCue) -> Int {
        let range = editedDisplayRange(of: cue)
        return editedClickTimes.count { range.contains($0) }
    }

    // MARK: - Planning

    private var plannedZooms: [ZoomCue] {
        if let cachedPlannedZooms {
            return cachedPlannedZooms
        }
        let planned = ZoomCuePlanner().cues(
            for: telemetry.clicks,
            in: manifest.pixelSize,
            duration: manifest.duration
        )
        let rebased = edit.clips.rebasing(planned)
        cachedPlannedZooms = rebased
        return rebased
    }

    /// A suggestion's identity across re-plans: the planner makes new UUIDs every time,
    /// but the same clicks always give the same start.
    nonisolated static func suggestionKey(_ cue: ZoomCue) -> Int {
        Int((cue.start * 1000).rounded())
    }
}
