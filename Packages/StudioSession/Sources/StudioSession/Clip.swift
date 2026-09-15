import CoreGraphics
import Foundation

/// A piece of the recording that survives into the edit (docs/09 U3.4).
///
/// Non-destructive: a clip names a range of the *source* and how fast to play it. Cutting
/// is therefore adding a boundary rather than removing footage, and undoing a cut is
/// removing the boundary rather than restoring bytes nobody kept. The recording on disk is
/// never touched by an edit.
public struct Clip: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// Where this piece starts in the recording.
    public var sourceStart: TimeInterval
    /// How long a piece of the recording it is, before speed.
    public var sourceDuration: TimeInterval
    /// How fast to play it. 1 is real time; 2 is twice as fast.
    public var speed: Double {
        didSet {
            let clamped = min(max(speed, Self.minimumSpeed), Self.maximumSpeed)
            if speed != clamped {
                speed = clamped
            }
        }
    }

    public init(
        id: UUID = UUID(),
        sourceStart: TimeInterval,
        sourceDuration: TimeInterval,
        speed: Double = 1
    ) {
        self.id = id
        self.sourceStart = max(sourceStart, 0)
        self.sourceDuration = max(sourceDuration, 0)
        self.speed = min(max(speed, Self.minimumSpeed), Self.maximumSpeed)
    }

    /// Below this the audio is unintelligible and the footage reads as broken rather than
    /// slow.
    public static let minimumSpeed: Double = 1
    /// Past eight times, a second of recording is an eighth of a second on screen and
    /// nothing in it can be followed.
    public static let maximumSpeed: Double = 8

    /// Shortest a clip may be after an edge-drag, in edited time.
    ///
    /// Below this a clip collapses into a handle nobody can grab, and the next drag
    /// deletes it by accident. Matching the floor Screendrop uses, so a trim that felt
    /// precise there feels the same here.
    public static let minimumEditedDuration: TimeInterval = 0.12

    /// How long this clip lasts in the finished video.
    public var editedDuration: TimeInterval {
        speed > 0 ? sourceDuration / speed : sourceDuration
    }

    public var sourceEnd: TimeInterval {
        sourceStart + sourceDuration
    }

    public var sourceRange: ClosedRange<TimeInterval> {
        sourceStart ... max(sourceEnd, sourceStart)
    }

    /// The pieces of this clip that remain after cutting `[start, end)` out of the recording.
    fileprivate func keepingOutside(start: TimeInterval, end: TimeInterval) -> [Clip] {
        let range = sourceStart ..< sourceEnd
        if end <= range.lowerBound || start >= range.upperBound {
            return [self]
        }
        var pieces: [Clip] = []
        if start > range.lowerBound {
            pieces.append(Clip(
                id: id,
                sourceStart: sourceStart,
                sourceDuration: start - sourceStart,
                speed: speed
            ))
        }
        if end < range.upperBound {
            pieces.append(Clip(
                sourceStart: end,
                sourceDuration: range.upperBound - end,
                speed: speed
            ))
        }
        return pieces
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceStart, sourceDuration, speed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            sourceStart: container.decodeIfPresent(TimeInterval.self, forKey: .sourceStart) ?? 0,
            sourceDuration: container.decodeIfPresent(TimeInterval.self, forKey: .sourceDuration) ?? 0,
            speed: container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        )
    }
}

/// The clips a recording is edited into, in order (docs/09 U3.4).
///
/// The mapping between source time and edited time lives here and nowhere else. Everything
/// downstream — the zoom cues, the cursor reconstruction, the export — works in edited time
/// because that is the timeline the viewer experiences; the telemetry arrives in source
/// time. One place that converts between them is one place to get it right.
public struct ClipTimeline: Sendable, Hashable, Codable {
    public var clips: [Clip]

    public init(clips: [Clip] = []) {
        self.clips = clips
    }

    /// The whole recording, uncut.
    public static func whole(duration: TimeInterval) -> ClipTimeline {
        ClipTimeline(clips: [Clip(sourceStart: 0, sourceDuration: max(duration, 0))])
    }

    /// How long the finished video is.
    public var editedDuration: TimeInterval {
        clips.reduce(0) { $0 + $1.editedDuration }
    }

    /// How much of the recording survives, before speed.
    public var sourceDuration: TimeInterval {
        clips.reduce(0) { $0 + $1.sourceDuration }
    }

    public var isEmpty: Bool {
        clips.isEmpty
    }

    // MARK: - Time

    /// Where a moment of the finished video is in the recording.
    ///
    /// Nil past the end, which is a real answer rather than a failure: an export asking
    /// for a frame past the last clip has run out of video.
    public func sourceTime(forEdited time: TimeInterval) -> TimeInterval? {
        guard time >= 0 else { return nil }
        var remaining = time
        for clip in clips {
            if remaining < clip.editedDuration {
                return clip.sourceStart + remaining * clip.speed
            }
            remaining -= clip.editedDuration
        }
        return nil
    }

    /// Where a moment of the recording ends up in the finished video.
    ///
    /// Nil when that moment was cut out — which is the answer a zoom cue anchored to a
    /// deleted moment needs, rather than a nearby time that would put it somewhere wrong.
    public func editedTime(forSource time: TimeInterval) -> TimeInterval? {
        var elapsed: TimeInterval = 0
        for clip in clips {
            if time >= clip.sourceStart, time < clip.sourceEnd {
                return elapsed + (time - clip.sourceStart) / clip.speed
            }
            elapsed += clip.editedDuration
        }
        return nil
    }

    /// Edited-time spans that overlap a source range, for drawing cues stored in source time.
    public func editedRanges(overlappingSource range: ClosedRange<TimeInterval>) -> [ClosedRange<TimeInterval>] {
        var elapsed: TimeInterval = 0
        var result: [ClosedRange<TimeInterval>] = []
        for clip in clips {
            let overlapStart = max(range.lowerBound, clip.sourceStart)
            let overlapEnd = min(range.upperBound, clip.sourceEnd)
            if overlapEnd > overlapStart {
                let editedStart = elapsed + (overlapStart - clip.sourceStart) / clip.speed
                let editedEnd = elapsed + (overlapEnd - clip.sourceStart) / clip.speed
                result.append(editedStart ... editedEnd)
            }
            elapsed += clip.editedDuration
        }
        return result
    }

    public func editedRange(forSource range: ClosedRange<TimeInterval>) -> ClosedRange<TimeInterval>? {
        let ranges = editedRanges(overlappingSource: range)
        guard let first = ranges.first, let last = ranges.last else { return nil }
        return first.lowerBound ... last.upperBound
    }

    /// Whether this moment of the recording still appears in the edit.
    public func containsSourceTime(_ time: TimeInterval) -> Bool {
        clips.contains { $0.sourceStart <= time && time < $0.sourceEnd }
    }

    /// Cuts a stretch of the recording out of every clip that overlaps it.
    public func removingSourceRange(from start: TimeInterval, to end: TimeInterval) -> ClipTimeline {
        guard end > start else { return self }
        let kept = clips.flatMap { $0.keepingOutside(start: start, end: end) }
        return ClipTimeline(clips: kept.filter { $0.sourceDuration > 0.02 })
    }

    /// Cuts several source ranges, merging overlaps and keeping the leading clip's id.
    public func removingSourceRanges(_ ranges: [ClosedRange<TimeInterval>]) -> ClipTimeline {
        let merged = Self.merged(ranges)
        var result = self
        for range in merged {
            result = result.removingSourceRange(from: range.lowerBound, to: range.upperBound)
        }
        return result
    }

    private static func merged(_ ranges: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        let sorted = ranges.filter { $0.upperBound > $0.lowerBound }.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = sorted.first else { return [] }
        var merged: [ClosedRange<TimeInterval>] = []
        for range in sorted.dropFirst() {
            if range.lowerBound <= current.upperBound {
                current = current.lowerBound ... max(current.upperBound, range.upperBound)
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    /// The clip playing at a moment of the finished video.
    public func clip(atEdited time: TimeInterval) -> Clip? {
        var remaining = time
        for clip in clips {
            if remaining < clip.editedDuration {
                return clip
            }
            remaining -= clip.editedDuration
        }
        return nil
    }

    // MARK: - Editing

    /// Splits the clip at a moment of the finished video into two.
    ///
    /// A split rather than a cut: two adjacent clips play exactly as one did, so splitting
    /// changes nothing until one side is deleted or retimed. That is what makes the
    /// operation safe to do speculatively.
    public mutating func split(atEdited time: TimeInterval) {
        var elapsed: TimeInterval = 0
        for (index, clip) in clips.enumerated() {
            let end = elapsed + clip.editedDuration
            if time > elapsed, time < end {
                let offsetInSource = (time - elapsed) * clip.speed
                // Both halves keep the speed: a split is not a retime.
                let first = Clip(
                    sourceStart: clip.sourceStart,
                    sourceDuration: offsetInSource,
                    speed: clip.speed
                )
                let second = Clip(
                    sourceStart: clip.sourceStart + offsetInSource,
                    sourceDuration: clip.sourceDuration - offsetInSource,
                    speed: clip.speed
                )
                clips.replaceSubrange(index ... index, with: [first, second])
                return
            }
            elapsed = end
        }
    }

    /// Drops everything before `time`, keeping the rest.
    ///
    /// Trimming the dead air off the front is the commonest edit anybody makes to a screen
    /// recording — the seconds spent reaching for the mouse after pressing Record. It was
    /// only reachable as split-then-delete-the-first-clip: two steps, in that order, with
    /// the playhead in the right place for both.
    ///
    /// A no-op at either end rather than an error. Trimming the start to the start asks for
    /// what is already true, and trimming it to the very end would delete the recording,
    /// which is not what a trim is for.
    public mutating func trimStart(toEdited time: TimeInterval) {
        guard time > 0, time < editedDuration else { return }
        split(atEdited: time)
        var elapsed: TimeInterval = 0
        var kept: [Clip] = []
        for clip in clips {
            if elapsed >= time - 0.0001 {
                kept.append(clip)
            }
            elapsed += clip.editedDuration
        }
        if !kept.isEmpty {
            clips = kept
        }
    }

    /// Drops everything after `time`, keeping the rest.
    public mutating func trimEnd(toEdited time: TimeInterval) {
        guard time > 0, time < editedDuration else { return }
        split(atEdited: time)
        var elapsed: TimeInterval = 0
        var kept: [Clip] = []
        for clip in clips {
            if elapsed < time - 0.0001 {
                kept.append(clip)
            }
            elapsed += clip.editedDuration
        }
        if !kept.isEmpty {
            clips = kept
        }
    }

    public mutating func remove(_ id: UUID) {
        clips.removeAll { $0.id == id }
    }

    /// Retimes one clip, leaving the rest alone.
    public mutating func setSpeed(_ speed: Double, for id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].speed = min(max(speed, Clip.minimumSpeed), Clip.maximumSpeed)
    }

    /// Shortens one clip from the left, in edited time.
    ///
    /// Dragging a clip's leading edge is how a start-trim actually happens on the
    /// timeline: the menu "Trim Start to Playhead" cuts the *whole* recording, but
    /// dragging this clip's in-point only skips the dead air at the start of that piece.
    public mutating func trimClipStart(at index: Int, toEdited editedStart: TimeInterval) {
        guard clips.indices.contains(index) else { return }
        let elapsed = editedStartTime(ofClipAt: index)
        let clip = clips[index]
        let end = elapsed + clip.editedDuration
        let latest = end - Clip.minimumEditedDuration
        guard latest > elapsed else { return }
        let clamped = min(max(editedStart, elapsed), latest)
        guard clamped > elapsed else { return }
        let skip = (clamped - elapsed) * clip.speed
        clips[index] = Clip(
            id: clip.id,
            sourceStart: clip.sourceStart + skip,
            sourceDuration: max(clip.sourceDuration - skip, 0),
            speed: clip.speed
        )
    }

    /// Shortens one clip from the right, in edited time.
    public mutating func trimClipEnd(at index: Int, toEdited editedEnd: TimeInterval) {
        guard clips.indices.contains(index) else { return }
        let elapsed = editedStartTime(ofClipAt: index)
        let clip = clips[index]
        let end = elapsed + clip.editedDuration
        let earliest = elapsed + Clip.minimumEditedDuration
        guard end > earliest else { return }
        let clamped = min(max(editedEnd, earliest), end)
        guard clamped < end else { return }
        let keep = (clamped - elapsed) * clip.speed
        clips[index] = Clip(
            id: clip.id,
            sourceStart: clip.sourceStart,
            sourceDuration: max(keep, 0),
            speed: clip.speed
        )
    }

    /// Where a clip begins on the finished timeline.
    public func editedStartTime(ofClipAt index: Int) -> TimeInterval {
        clips.prefix(index).reduce(0) { $0 + $1.editedDuration }
    }

    /// Rewrites zoom cues from source time into edited time, dropping the ones whose
    /// moment was cut.
    ///
    /// Cues live in edited time because that is what the viewer experiences, but a cue
    /// generated from clicks starts life in source time. A cue whose anchor moment no
    /// longer exists is dropped rather than slid to a neighbouring moment, which would
    /// zoom into something the user never chose.
    /// Keeps cues whose source start still exists. Cues are stored in source time
    /// (docs/16 STU-A3); a cut drops the ones that pointed at removed footage.
    public func rebasing(_ cues: [ZoomCue]) -> [ZoomCue] {
        cues.filter { editedTime(forSource: $0.start) != nil }
    }

    /// Converts v1 cues (edited time) into source time.
    public func migratingZoomsFromEditedTime(_ cues: [ZoomCue]) -> [ZoomCue] {
        cues.compactMap { cue in
            guard let start = sourceTime(forEdited: cue.start) else { return nil }
            var migrated = cue
            migrated.start = start
            let speed = clip(atEdited: cue.start)?.speed ?? 1
            migrated.duration = cue.duration * speed
            return migrated
        }
    }

    private enum CodingKeys: String, CodingKey {
        case clips
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(clips: container.decodeIfPresent([Clip].self, forKey: .clips) ?? [])
    }
}
