import CoreGraphics
import Foundation
import StudioSession

/// A stretch of the recording proposed for removal (docs/09 U3.6).
public struct ProposedCut: Sendable, Hashable, Identifiable {
    public enum Reason: String, Sendable, Hashable {
        case fillerWord
        case silence

        public var title: String {
            switch self {
            case .fillerWord: String(localized: "Filler word", bundle: .module)
            case .silence: String(localized: "Silence", bundle: .module)
            }
        }
    }

    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var reason: Reason
    /// What was cut, for the review list — "um", or how long the pause was.
    public var label: String

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        reason: Reason,
        label: String
    ) {
        self.id = id
        self.start = max(start, 0)
        self.end = max(end, self.start)
        self.reason = reason
        self.label = label
    }

    public var duration: TimeInterval {
        end - start
    }

    public var range: ClosedRange<TimeInterval> {
        start ... end
    }
}

/// Proposes cuts from a transcript (docs/09 U3.6).
///
/// Pure, and separate from whatever produced the transcript, for two reasons. The obvious
/// one is testability. The other is that transcription is the part that changes with the
/// operating system — `SFSpeechRecognizer` on macOS 14 and 15, `SpeechAnalyzer` on 26 — and
/// a planner tied to either would have to be written twice.
///
/// The rule that matters most is the last one: **cuts bite into silence, never into
/// words**. A cut that clips the start of a word is instantly audible and makes the whole
/// feature feel unsafe, which is how a user ends up doing it by hand instead.
public struct TranscriptCutPlanner: Sendable {
    /// A pause longer than this is worth removing.
    ///
    /// Just over a second: shorter pauses are how speech is punctuated, and removing them
    /// makes a person sound like they are reading a list.
    public var minimumSilence: TimeInterval
    /// How much silence to leave at each end of a removed pause.
    ///
    /// Without it, the words either side are butted together and the result sounds
    /// clipped — the characteristic artefact of automatic silence removal. A quarter of a
    /// second each side shortens a long pause to about half a second rather than deleting
    /// it (docs/17 T-STU-6): the speaker still breathes, the viewer still gets a beat.
    public var silencePadding: TimeInterval
    /// Whether to propose removing filler words.
    public var removesFillers: Bool
    /// Whether to propose removing long pauses.
    public var removesSilences: Bool
    /// A plan that would throw away more than this of the recording needs confirmation
    /// before it is applied (docs/13 T0.3, T-C2).
    public var maximumRemovedFraction: Double

    public init(
        minimumSilence: TimeInterval = 1.1,
        silencePadding: TimeInterval = 0.25,
        removesFillers: Bool = true,
        removesSilences: Bool = true,
        maximumRemovedFraction: Double = 0.4
    ) {
        self.minimumSilence = max(minimumSilence, 0.2)
        self.silencePadding = max(silencePadding, 0)
        self.removesFillers = removesFillers
        self.removesSilences = removesSilences
        self.maximumRemovedFraction = min(max(maximumRemovedFraction, 0.05), 0.95)
    }

    /// The words treated as filler.
    ///
    /// Deliberately short. Every addition is a word somebody uses deliberately in some
    /// sentence, and a planner that removes "like" from "it works like this" is worse than
    /// one that leaves a few "um"s in.
    public static let fillerWords: Set<String> = [
        "um", "uh", "erm", "er", "ah", "hmm", "mm", "mmm", "uhm", "eh"
    ]

    /// The filler words for a transcript's language, or nil when Kadr has no list for it
    /// (docs/18 STU-10).
    ///
    /// "um" and "uh" are English; offering "Filler words" for a Ukrainian or Japanese
    /// recording proposed nothing and looked broken. A transcript with no recorded locale
    /// predates the field and was English.
    public static func fillerWords(forLocale identifier: String) -> Set<String>? {
        guard !identifier.isEmpty else { return fillerWords }
        switch Locale(identifier: identifier).language.languageCode?.identifier {
        case "en": return fillerWords
        case "de": return ["äh", "ähm", "öh", "öhm", "hm", "hmm"]
        case "fr": return ["euh", "heu", "hum", "bah"]
        case "es": return ["eh", "em", "ehm", "mmm"]
        case "nl": return ["eh", "ehm", "uh", "uhm"]
        default: return nil
        }
    }

    /// Cuts for a transcript.
    ///
    /// Ordered by time and never overlapping, so applying them is a walk rather than an
    /// interval-merge at the call site.
    ///
    /// - Parameter protected: stretches that are never cut for being silent — where the
    ///   pointer moved, a key was pressed or a button clicked (docs/17 T-STU-6). In a
    ///   screen recording the quiet part is often the demonstration itself.
    ///
    /// Planned from the speaker's words only: a recognised word from recorded system
    /// audio is the app being demonstrated, not the narrator, and an "um" in somebody
    /// else's video is not the user's to cut (docs/03 §1.9).
    public func cuts(
        for transcript: Transcript,
        duration: TimeInterval,
        protecting protected: [ClosedRange<TimeInterval>] = []
    ) -> [ProposedCut] {
        // The locale travels with the words: it picks the filler list (docs/18 STU-10).
        let speaker = Transcript(
            words: transcript.words.filter { $0.track != .system },
            localeIdentifier: transcript.localeIdentifier
        )
        guard !speaker.isEmpty else { return [] }
        var cuts: [ProposedCut] = []

        if removesFillers {
            cuts.append(contentsOf: fillerCuts(in: speaker))
        }
        if removesSilences {
            let ranges = Self.merged(protected)
            cuts.append(contentsOf: silenceCuts(in: speaker, duration: duration)
                .flatMap { Self.subtracting(ranges, from: $0) })
        }
        return merged(cuts.sorted { $0.start < $1.start })
    }

    /// When something happened on screen, padded, in recording time (docs/17 T-STU-6).
    ///
    /// Clicks and keystrokes each protect a little either side; pointer travel protects
    /// the stretch it covered. A pointer that drifts a point or two is a hand resting on
    /// the mouse, not a demonstration, so small moves are ignored.
    public static func activityRanges(
        in telemetry: InputTelemetry,
        padding: TimeInterval = 0.4,
        minimumTravel: CGFloat = 6
    ) -> [ClosedRange<TimeInterval>] {
        var ranges: [ClosedRange<TimeInterval>] = []
        for click in telemetry.clicks where click.isDown {
            ranges.append(max(click.time - padding, 0) ... click.time + padding)
        }
        for key in telemetry.keystrokes {
            ranges.append(max(key.time - padding, 0) ... key.time + padding)
        }
        var anchor = telemetry.pointer.first
        for sample in telemetry.pointer.dropFirst() {
            guard let from = anchor else { break }
            let travel = hypot(sample.position.x - from.position.x, sample.position.y - from.position.y)
            if travel >= minimumTravel {
                ranges.append(max(from.time - padding, 0) ... sample.time + padding)
                anchor = sample
            } else if sample.time - from.time > 0.5 {
                // Re-anchor after a still spell, so a slow drift over minutes is not
                // mistaken for one long gesture.
                anchor = sample
            }
        }
        return merged(ranges)
    }

    /// Sorted, with touching and overlapping ranges joined.
    static func merged(_ ranges: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound ... max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// The parts of `cut` outside `protected` (sorted, merged), each still worth cutting.
    static func subtracting(
        _ protected: [ClosedRange<TimeInterval>],
        from cut: ProposedCut,
        minimumPiece: TimeInterval = 0.3
    ) -> [ProposedCut] {
        var pieces: [ProposedCut] = []
        var start = cut.start
        for range in protected where range.upperBound > start && range.lowerBound < cut.end {
            if range.lowerBound - start >= minimumPiece {
                pieces.append(ProposedCut(start: start, end: range.lowerBound, reason: cut.reason, label: cut.label))
            }
            start = max(start, range.upperBound)
        }
        if cut.end - start >= minimumPiece {
            pieces.append(ProposedCut(
                id: pieces.isEmpty && start == cut.start ? cut.id : UUID(),
                start: start,
                end: cut.end,
                reason: cut.reason,
                label: cut.label
            ))
        }
        return pieces
    }

    /// How much of the recording these cuts would throw away.
    public func removedFraction(of cuts: [ProposedCut], duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        let removed = cuts.reduce(0.0) { $0 + $1.duration }
        return min(removed / duration, 1)
    }

    public func exceedsRemovalCap(_ cuts: [ProposedCut], duration: TimeInterval) -> Bool {
        removedFraction(of: cuts, duration: duration) > maximumRemovedFraction
    }

    /// Every filler word, padded a little into the silence around it.
    private func fillerCuts(in transcript: Transcript) -> [ProposedCut] {
        let words = transcript.words
        let fillers = Self.fillerWords(forLocale: transcript.localeIdentifier) ?? []
        return words.enumerated().compactMap { index, word in
            guard fillers.contains(word.normalized) else { return nil }
            let previousEnd = index > 0 ? words[index - 1].end : max(word.start - 0.12, 0)
            let nextStart = index + 1 < words.count ? words[index + 1].start : word.end + 0.12
            let padBefore = min(0.12, max((word.start - previousEnd) / 2, 0))
            let padAfter = min(0.12, max((nextStart - word.end) / 2, 0))
            return ProposedCut(
                start: word.start - padBefore,
                end: word.end + padAfter,
                reason: .fillerWord,
                label: word.text
            )
        }
    }

    /// Every gap longer than the threshold, padded inwards.
    ///
    /// Inwards is the whole trick: the cut starts a little *after* the previous word ends
    /// and finishes a little *before* the next one begins, so what is removed is entirely
    /// silence. Padding outwards, or not padding at all, is what clips words.
    private func silenceCuts(in transcript: Transcript, duration: TimeInterval) -> [ProposedCut] {
        var cuts: [ProposedCut] = []
        var previousEnd: TimeInterval = 0

        for word in transcript.words {
            let gap = word.start - previousEnd
            if gap >= minimumSilence {
                let start = previousEnd + silencePadding
                let end = word.start - silencePadding
                if end > start {
                    cuts.append(ProposedCut(
                        start: start,
                        end: end,
                        reason: .silence,
                        label: String(format: "Shorten a %.1f s pause", gap)
                    ))
                }
            }
            previousEnd = max(previousEnd, word.end)
        }

        // The tail: silence after the last word is as removable as silence in the middle,
        // and is the most common thing left in an unedited recording.
        let tail = duration - previousEnd
        if tail >= minimumSilence {
            let start = previousEnd + silencePadding
            if duration > start {
                cuts.append(ProposedCut(
                    start: start,
                    end: duration,
                    reason: .silence,
                    label: String(format: "%.1f s at the end", tail)
                ))
            }
        }
        return cuts
    }

    /// Joins cuts that touch or overlap.
    ///
    /// A filler word inside a pause produces two proposals for one stretch of audio, and
    /// applying both would remove the same range twice.
    private func merged(_ cuts: [ProposedCut]) -> [ProposedCut] {
        var merged: [ProposedCut] = []
        for cut in cuts {
            guard let last = merged.last, cut.start <= last.end else {
                merged.append(cut)
                continue
            }
            // The longer reason wins the label: a pause containing an "um" reads better as
            // a pause than as an "um".
            let combined = ProposedCut(
                id: last.id,
                start: last.start,
                end: max(last.end, cut.end),
                reason: last.duration >= cut.duration ? last.reason : cut.reason,
                label: last.duration >= cut.duration ? last.label : cut.label
            )
            merged[merged.count - 1] = combined
        }
        return merged
    }

    /// The timeline with these cuts subtracted from the current clips (docs/16 STU-C3).
    public func applying(_ cuts: [ProposedCut], to timeline: ClipTimeline) -> ClipTimeline {
        timeline.removingSourceRanges(cuts.map(\.range))
    }

    /// The timeline with these cuts applied.
    ///
    /// The planner proposes and the timeline disposes: cuts are turned into clip
    /// boundaries, which are undoable and non-destructive like every other edit. Nothing
    /// here touches the recording.
    public func applying(_ cuts: [ProposedCut], to duration: TimeInterval) -> ClipTimeline {
        applying(cuts, to: .whole(duration: duration))
    }
}
