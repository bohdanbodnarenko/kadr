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
            if clip.sourceRange.contains(time) {
                return elapsed + (time - clip.sourceStart) / clip.speed
            }
            elapsed += clip.editedDuration
        }
        return nil
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

    public mutating func remove(_ id: UUID) {
        clips.removeAll { $0.id == id }
    }

    /// Retimes one clip, leaving the rest alone.
    public mutating func setSpeed(_ speed: Double, for id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].speed = min(max(speed, Clip.minimumSpeed), Clip.maximumSpeed)
    }

    /// Rewrites zoom cues from source time into edited time, dropping the ones whose
    /// moment was cut.
    ///
    /// Cues live in edited time because that is what the viewer experiences, but a cue
    /// generated from clicks starts life in source time. A cue whose anchor moment no
    /// longer exists is dropped rather than slid to a neighbouring moment, which would
    /// zoom into something the user never chose.
    public func rebasing(_ cues: [ZoomCue]) -> [ZoomCue] {
        cues.compactMap { cue in
            guard let start = editedTime(forSource: cue.start) else { return nil }
            var rebased = cue
            rebased.start = start
            // The hold shortens with the speed of whatever it lands in.
            let speed = clip(atEdited: start)?.speed ?? 1
            rebased.duration = cue.duration / speed
            return rebased
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
