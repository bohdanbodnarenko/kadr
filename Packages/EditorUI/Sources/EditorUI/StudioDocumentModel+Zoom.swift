import CoreGraphics
import Foundation
import StudioSession

/// How a zoom aims (docs/09 U3.3).
///
/// Pointer-follow is explicit: adding a zoom still pins to where the pointer was, because
/// chasing it for the life of the cue is how automatic zooms look cheap.
public enum StudioZoomFocus: String, CaseIterable, Sendable {
    case pointer
    case fixed
    case centre

    var title: String {
        switch self {
        case .pointer:
            "Pointer"
        case .fixed:
            "Fixed"
        case .centre:
            "Centre"
        }
    }
}

/// Placing, aiming and retiming zooms (docs/09 U3.3).
@MainActor
public extension StudioDocumentModel {
    /// Adds a zoom over the playhead, anchored where the pointer was.
    ///
    /// Anchored at the pointer rather than the centre because a zoom to the middle of the
    /// screen is almost never what somebody wants: they are zooming to whatever they were
    /// doing, and where the pointer was is the best evidence of that available.
    func addZoom(duration: TimeInterval = 3, magnification: Double = 2) {
        // A cue occupies its hold *and* both of its moves, so the span to fit inside the
        // recording is longer than the duration asked for. Fitting the hold alone puts the
        // move out past the end, where it never plays and the recording ends mid-zoom.
        let transition = Self.defaultTransition
        let footprint = duration + transition * 2
        let start = max(0, min(playhead, edit.duration - footprint))
        let available = max(edit.duration - start - transition * 2, 0.1)
        let sourceStart = sourceTime(forEdited: start)
        let speed = edit.clips.clip(atEdited: start)?.speed ?? 1
        let cue = ZoomCue(
            start: sourceStart,
            duration: min(duration, available) * speed,
            magnification: magnification,
            anchor: .fixed(pointerPosition(at: start) ?? centreOfFrame),
            transitionDuration: transition
        )
        change { $0.zooms.append(cue) }
        selectedZoom = cue.id
    }

    /// Places a zoom across a dragged range on the zoom lane.
    ///
    /// The range is the whole cue — move in, hold, move out — because that is what the
    /// lane draws. A drag that is too short to hold a zoom is ignored, so a click still
    /// only scrubs. Existing cues stop the span, the way they do in Screendrop.
    func addZoom(from start: TimeInterval, to end: TimeInterval) {
        let span = proposedZoomSpan(origin: start, current: end)
        let length = span.high - span.low
        guard length >= Self.minimumDraggedZoom else { return }
        let transition = min(Self.defaultTransition, length / 4)
        let hold = max(length - transition * 2, 0.2)
        let cue = ZoomCue(
            start: sourceTime(forEdited: span.low),
            duration: hold * (edit.clips.clip(atEdited: span.low)?.speed ?? 1),
            magnification: 2,
            anchor: .fixed(pointerPosition(at: span.low) ?? centreOfFrame),
            transitionDuration: transition
        )
        change { $0.zooms.append(cue) }
        selectedZoom = cue.id
    }

    /// Shortest drag on the zoom lane that still becomes a cue rather than a scrub.
    static let minimumDraggedZoom: TimeInterval = 0.35

    /// How long a new cue takes to move in, and out again.
    static let defaultTransition: TimeInterval = 0.6

    /// The span a drag on the zoom lane would occupy, stopped at neighbouring cues.
    func proposedZoomSpan(
        origin: TimeInterval,
        current: TimeInterval
    ) -> (low: TimeInterval, high: TimeInterval) {
        let origin = min(max(origin, 0), edit.duration)
        let current = min(max(current, 0), edit.duration)
        if edit.zooms.contains(where: { editedDisplayRange(of: $0).contains(origin) }) {
            return (origin, origin)
        }
        let lowerLimit = edit.zooms.map { editedDisplayRange(of: $0).upperBound }.filter { $0 <= origin }.max() ?? 0
        let upperLimit = edit.zooms.map { editedDisplayRange(of: $0).lowerBound }.filter { $0 >= origin }.min()
            ?? edit.duration
        let low = max(min(origin, current), lowerLimit)
        let high = min(max(origin, current), upperLimit)
        return (low, high)
    }

    /// Points the selected zoom at where the pointer was at the playhead.
    func aimSelectedZoomAtPointer() {
        guard let id = selectedZoom, let point = pointerPosition(at: playhead) else { return }
        updateZoom(id) { $0.anchor = .fixed(point) }
    }

    /// How the selected cue aims: follow the pointer, sit still, or sit in the middle.
    func zoomFocus(of id: ZoomCue.ID) -> StudioZoomFocus {
        switch edit.zooms.first(where: { $0.id == id })?.anchor {
        case .pointer:
            .pointer
        case .centre:
            .centre
        default:
            .fixed
        }
    }

    /// Sets whether a cue follows the pointer, stays pinned, or aims at the middle.
    ///
    /// Switching to Fixed snapshots the pointer at the playhead when the cue was following
    /// or centred, so the camera stays where it was looking rather than jumping to (0, 0).
    func setZoomFocus(_ id: ZoomCue.ID, to focus: StudioZoomFocus) {
        switch focus {
        case .pointer:
            updateZoom(id) {
                $0.anchor = .pointer
                if $0.boundsBias == 0 {
                    $0.boundsBias = ZoomCue.defaultPointerBoundsBias
                }
            }
        case .centre:
            updateZoom(id) { $0.anchor = .centre }
        case .fixed:
            guard let cue = edit.zooms.first(where: { $0.id == id }) else { return }
            if case .fixed = cue.anchor {
                return
            }
            let point: CGPoint = if case .cluster = cue.anchor {
                cue.anchor.point(in: manifest.pixelSize)
            } else {
                pointerPosition(at: playhead) ?? cue.anchor.point(in: manifest.pixelSize)
            }
            updateZoom(id) { $0.anchor = .fixed(point) }
        }
    }

    /// Recorded clicks on the edited timeline, for ticks on the zoom lane.
    var editedClickTimes: [TimeInterval] {
        editedTelemetry.clicks.filter(\.isDown).map(\.time)
    }

    var hasPointerAtPlayhead: Bool {
        pointerPosition(at: playhead) != nil
    }

    /// Replaces the zooms with ones planned from the recorded clicks.
    ///
    /// Wholesale rather than additive: "add smart zooms" run twice should give the same
    /// result as run once, and appending would stack cues on top of each other.
    func planSmartZooms() {
        let planner = ZoomCuePlanner()
        // Planned from the sidecar in source time, then rewritten onto the edited
        // timeline. Clicks already on the edited timeline would be planned twice against
        // cuts that have already moved them, and a second press of the button would not
        // be a no-op (docs/10 R0.2, R3.3).
        let planned = planner.cues(
            for: telemetry.clicks,
            in: manifest.pixelSize,
            duration: manifest.duration
        )
        let rebased = edit.clips.rebasing(planned)
        guard !rebased.isEmpty else {
            failure = .noClickClusters()
            return
        }
        change { $0.zooms = $0.clips.rebasing(planned) }
        selectedZoom = nil
    }

    func removeSelectedZoom() {
        guard let selectedZoom else { return }
        change { $0.zooms.removeAll { $0.id == selectedZoom } }
        self.selectedZoom = nil
    }

    /// Clears every zoom. Footage is untouched; the cues can be planned again.
    func resetZooms() {
        guard !edit.zooms.isEmpty else { return }
        change { $0.zooms = [] }
        selectedZoom = nil
    }

    /// Updates one cue in place.
    ///
    /// - Parameter gesture: names a continuous interaction, so dragging a cue along the
    ///   timeline is one undo step rather than one per pixel of travel (docs/11 S2).
    func updateZoom(
        _ id: ZoomCue.ID,
        coalescingAs gesture: String? = nil,
        _ mutate: (inout ZoomCue) -> Void
    ) {
        change(coalescingAs: gesture) { edit in
            guard let index = edit.zooms.firstIndex(where: { $0.id == id }) else { return }
            mutate(&edit.zooms[index])
        }
    }

    /// Moves a cue to a new start, keeping it inside the recording.
    ///
    /// Clamped so the whole cue — its hold *and* both of its moves — still fits. A cue that
    /// runs off the end never finishes playing, and the recording ends mid-zoom.
    func moveZoom(_ id: ZoomCue.ID, to start: TimeInterval) {
        guard let cue = edit.zooms.first(where: { $0.id == id }) else { return }
        let edited = editedDisplayRange(of: cue)
        let footprint = edited.upperBound - edited.lowerBound
        let latest = max(edit.duration - footprint, 0)
        let source = sourceTime(forEdited: min(max(start, 0), latest))
        updateZoom(id, coalescingAs: "zoom.start.\(id)") { $0.start = source }
    }

    /// Sets a cue's occupied range from the lane's resize handles.
    ///
    /// Transition time is kept when there is room, and shrunk when the drag is shorter
    /// than the original moves, so a handle can still make a brief zoom.
    func setZoomRange(_ id: ZoomCue.ID, start: TimeInterval, end: TimeInterval) {
        guard let cue = edit.zooms.first(where: { $0.id == id }) else { return }
        let others = edit.zooms.filter { $0.id != id }
        let lowerLimit = others
            .map { editedDisplayRange(of: $0).upperBound }
            .filter { $0 <= editedDisplayRange(of: cue).lowerBound }
            .max() ?? 0
        let upperLimit = others
            .map { editedDisplayRange(of: $0).lowerBound }
            .filter { $0 >= editedDisplayRange(of: cue).upperBound }
            .min() ?? edit.duration
        var low = min(max(min(start, end), lowerLimit), upperLimit)
        var high = min(max(max(start, end), lowerLimit), upperLimit)
        let minHold: TimeInterval = 0.2
        if high - low < minHold {
            high = min(low + minHold, upperLimit)
            low = max(high - minHold, lowerLimit)
        }
        let span = high - low
        let transition = min(max(min(cue.transitionDuration, span / 4), 0.1), 2)
        let speed = edit.clips.clip(atEdited: low)?.speed ?? 1
        updateZoom(id, coalescingAs: "zoom.range.\(id)") {
            $0.start = sourceTime(forEdited: low)
            $0.transitionDuration = transition
            $0.duration = max(span - transition * 2, minHold) * speed
        }
    }

    /// Where the pointer was at an instant, in recorded pixels.
    ///
    /// Asked in edited time, because that is what the playhead is.
    func pointerPosition(at time: TimeInterval) -> CGPoint? {
        let pointer = editedTelemetry.pointer
        return pointer.last { $0.time <= time }?.position ?? pointer.first?.position
    }

    var centreOfFrame: CGPoint {
        CGPoint(x: manifest.pixelSize.width / 2, y: manifest.pixelSize.height / 2)
    }

    func sourceTime(forEdited time: TimeInterval) -> TimeInterval {
        edit.clips.sourceTime(forEdited: time) ?? time
    }

    func editedDisplayRange(of cue: ZoomCue) -> ClosedRange<TimeInterval> {
        edit.clips.editedRange(forSource: cue.start ... cue.end) ?? cue.start ... cue.end
    }
}
