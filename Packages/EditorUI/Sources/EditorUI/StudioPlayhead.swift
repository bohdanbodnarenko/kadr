import Foundation
import Observation

/// The two times that move while nothing else does: the playhead and the hover (docs/11 S2).
///
/// Its own observable, held by `StudioDocumentModel`, so that a write here invalidates only
/// the views that read *these* properties. Playback writes `time` thirty times a second and
/// the pointer writes `hoverTime` on every mouse move; on the document model either one
/// re-evaluated the timeline, the transport, the inspector and the transcript each time.
///
/// Write through `StudioDocumentModel.playhead` rather than here, so the clamp and the
/// derived state (`currentClipIndex`) stay in step. Read here from leaf views that draw
/// the time — the needle, the clock, the active word — and nowhere else.
@MainActor
@Observable
public final class StudioPlayhead {
    /// The playhead, in edited time.
    public internal(set) var time: TimeInterval = 0

    /// Edited time under the pointer on the timeline, or nil when it is elsewhere.
    public internal(set) var hoverTime: TimeInterval?

    public nonisolated init() {}
}
