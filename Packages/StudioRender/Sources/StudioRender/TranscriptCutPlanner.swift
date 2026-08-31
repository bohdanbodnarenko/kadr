import Foundation
import StudioSession

/// A stretch of the recording proposed for removal (docs/09 U3.6).
public struct ProposedCut: Sendable, Hashable, Identifiable {
    public enum Reason: String, Sendable, Hashable {
        case fillerWord
        case silence

        public var title: String {
            switch self {
            case .fillerWord: "Filler word"
            case .silence: "Silence"
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
    /// clipped — the characteristic artefact of automatic silence removal.
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
        silencePadding: TimeInterval = 0.35,
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

    /// Cuts for a transcript.
    ///
    /// Ordered by time and never overlapping, so applying them is a walk rather than an
    /// interval-merge at the call site.
    public func cuts(for transcript: Transcript, duration: TimeInterval) -> [ProposedCut] {
        guard !transcript.isEmpty else { return [] }
        var cuts: [ProposedCut] = []

        if removesFillers {
            cuts.append(contentsOf: fillerCuts(in: transcript))
        }
        if removesSilences {
            cuts.append(contentsOf: silenceCuts(in: transcript, duration: duration))
        }
        return merged(cuts.sorted { $0.start < $1.start })
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

    /// Every filler word, cut exactly around itself.
    private func fillerCuts(in transcript: Transcript) -> [ProposedCut] {
        transcript.words.compactMap { word in
            guard Self.fillerWords.contains(word.normalized) else { return nil }
            return ProposedCut(
                start: word.start,
                end: word.end,
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
                        label: String(format: "%.1f s pause", gap)
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

    /// The timeline with these cuts applied.
    ///
    /// The planner proposes and the timeline disposes: cuts are turned into clip
    /// boundaries, which are undoable and non-destructive like every other edit. Nothing
    /// here touches the recording.
    public func applying(_ cuts: [ProposedCut], to duration: TimeInterval) -> ClipTimeline {
        guard !cuts.isEmpty else { return .whole(duration: duration) }

        var clips: [Clip] = []
        var cursor: TimeInterval = 0
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            if cut.start > cursor {
                clips.append(Clip(sourceStart: cursor, sourceDuration: cut.start - cursor))
            }
            cursor = max(cursor, cut.end)
        }
        if cursor < duration {
            clips.append(Clip(sourceStart: cursor, sourceDuration: duration - cursor))
        }
        return ClipTimeline(clips: clips)
    }
}
