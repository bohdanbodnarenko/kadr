import CoreGraphics
import Foundation
import StudioSession

/// What the studio preview is being asked to show (docs/09 U3.3, docs/10 R1.1).
///
/// Everything the picture depends on apart from the playhead, as one value — so "does the
/// preview need rebuilding" is an equality check, and "how much of it" is
/// `StudioPlaybackRebuild.between(_:_:)`. Files are named rather than resolved: resolving
/// a URL is a `stat`, and this is built on the main actor for every slider tick.
struct StudioPreviewRequest: Sendable, Equatable {
    /// The edit as the preview draws it — uncropped while a crop is being placed.
    var edit: StudioEdit
    /// The transcript the captions are drawn from; empty when there is none.
    var transcript: Transcript
    /// The picture's longest edge in pixels, already bucketed.
    var longestEdge: Int

    init(
        edit: StudioEdit,
        transcript: Transcript?,
        longestEdge: Int,
        isCropping: Bool,
        isAimingZoom: Bool = false
    ) {
        var shown = edit
        if isCropping {
            shown.cropRect = nil
        }
        // Aiming shows the picture a zoom is aimed *at*, not the picture it produces —
        // otherwise the target rectangle would be drawn over its own result.
        if isAimingZoom {
            shown.zooms = []
        }
        self.edit = shown
        self.transcript = transcript ?? Transcript()
        self.longestEdge = longestEdge
    }

    /// The same request at another size, for the skim thumbnail.
    func resized(to longestEdge: Int) -> StudioPreviewRequest {
        var copy = self
        copy.longestEdge = longestEdge
        return copy
    }
}

/// How much of the player has to be rebuilt for a new request.
///
/// Two very different prices. A new *picture* — a zoom moved, a colour changed, the window
/// resized — is a new composer handed to the same `AVPlayerItem`, which keeps its decoder,
/// its buffered frames and its place. A new *timeline* — a cut, a speed change, a different
/// soundtrack — is a new composition, and AVFoundation only takes one of those as a new
/// item. Getting this wrong in the cheap direction plays the old cut; getting it wrong in
/// the expensive direction tears down the decoder on every slider tick.
enum StudioPlaybackRebuild: Equatable {
    case nothing
    case picture
    case timeline

    static func between(_ old: StudioPreviewRequest?, _ new: StudioPreviewRequest) -> StudioPlaybackRebuild {
        guard let old else { return .timeline }
        guard old != new else { return .nothing }
        let before = old.edit
        let after = new.edit
        // The composition carries the clips, the audio and the camera track, and nothing
        // else. The display name is in the key because re-importing a file with the same
        // extension reuses the same file name: the name alone would keep playing the old
        // soundtrack.
        let timelineChanged = before.clips != after.clips
            || before.mutesAudio != after.mutesAudio
            || before.soundtrackFileName != after.soundtrackFileName
            || before.soundtrackDisplayName != after.soundtrackDisplayName
            || before.camera.isVisible != after.camera.isVisible
        return timelineChanged ? .timeline : .picture
    }
}

/// Picture sizes the preview is rendered at.
///
/// Bucketed because the size is baked into the render plan, and a plan costs a spring
/// integration over the whole recording. Rebuilding one for every pixel of a window drag
/// would be the very main-actor stall R1.1 removed; rebuilding one per bucket costs a
/// handful over the lifetime of a window. Rounded *up*, so the picture is never upscaled
/// on a display that asked for more pixels than it got.
enum StudioPreviewSize {
    static let buckets = [540, 720, 1080, 1440, 2160]

    /// The skim thumbnail's longest edge: 160 points of popover at up to 2×.
    static let skimLongestEdge = 320

    /// Before the view has reported a size — and in a model with no view at all.
    static let fallbackLongestEdge = 1080

    static func bucket(forLongestEdge pixels: CGFloat) -> Int {
        guard pixels.isFinite, pixels > 0 else { return fallbackLongestEdge }
        return buckets.first { CGFloat($0) >= pixels } ?? buckets[buckets.count - 1]
    }

    static func bucket(for size: CGSize, backingScale: CGFloat) -> Int {
        bucket(forLongestEdge: max(size.width, size.height) * max(backingScale, 1))
    }
}

/// One expensive job at a time, and only the newest request waiting behind it.
///
/// A slider sends a request per pixel of travel and a pipeline build takes tens of
/// milliseconds on a long recording. Queueing every request would have the preview
/// replaying the whole drag for seconds after the mouse stopped; cancelling the running
/// build on every tick would mean it never finishes. Latest-wins does neither: the build
/// in flight completes (and is shown — it is still newer than what is on screen), and
/// whatever arrived meanwhile collapses to its last value.
struct StudioLatestWins<Request: Equatable> {
    private(set) var running: Request?
    private(set) var queued: Request?

    var isIdle: Bool {
        running == nil && queued == nil
    }

    /// Offers a request. Returns it if it should start now.
    mutating func submit(_ request: Request) -> Request? {
        guard running != nil else {
            running = request
            return request
        }
        // Asking again for exactly what is already being built is not a new job, and a
        // queued job that has been overtaken by a return to the running one is stale.
        queued = request == running ? nil : request
        return nil
    }

    /// Marks the running job finished. Returns the next one to start, if any.
    mutating func finish() -> Request? {
        running = queued
        queued = nil
        return running
    }

    mutating func reset() {
        running = nil
        queued = nil
    }
}

/// Frame-accurate scrubbing without a queue of seeks (Apple Technical Q&A QA1820).
///
/// A zero-tolerance seek decodes from the previous keyframe, and a scrub asks for one per
/// mouse event. Issuing each would have AVFoundation cancel all but the last anyway, after
/// starting every decode. Chasing issues one seek; while it runs only the latest target is
/// remembered; when it lands, the player seeks on to that target if it differs. The picture
/// keeps up with the pointer as fast as the decoder allows and settles on the exact frame.
struct StudioSeekChase: Equatable {
    private(set) var inFlight: TimeInterval?
    private(set) var pending: TimeInterval?

    /// Asks for `time`. Returns it if a seek should be issued now.
    mutating func request(_ time: TimeInterval) -> TimeInterval? {
        guard inFlight != nil else {
            inFlight = time
            return time
        }
        pending = time
        return nil
    }

    /// The seek in flight landed (or was superseded). Returns the next target, if any.
    mutating func completed() -> TimeInterval? {
        let landed = inFlight
        inFlight = nil
        guard let next = pending else { return nil }
        pending = nil
        guard next != landed else { return nil }
        inFlight = next
        return next
    }

    mutating func reset() {
        inFlight = nil
        pending = nil
    }
}
