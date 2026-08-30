import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// Proposing cuts from what was said (docs/09 U3.6).
///
/// The rule that matters most is that cuts bite into silence and never into words: a cut
/// that clips the start of a word is instantly audible and makes the whole feature feel
/// unsafe, which is how somebody ends up doing it by hand instead.
@Suite("Transcript cut planner")
struct TranscriptCutPlannerTests {
    private let planner = TranscriptCutPlanner()

    private func transcript(_ words: [TranscriptWord]) -> Transcript {
        Transcript(words: words)
    }

    /// Terser than the initialiser at the twenty-odd call sites below.
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    // MARK: - Filler words

    @Test("A filler word is proposed for removal")
    func fillerWordIsCut() throws {
        let script = transcript([
            word("So", 0, 0.4),
            word("um", 0.5, 0.8),
            word("here", 0.9, 1.3)
        ])
        let cuts = planner.cuts(for: script, duration: 2)
        let filler = try #require(cuts.first { $0.reason == .fillerWord })

        #expect(abs(filler.start - 0.5) < 0.001)
        #expect(abs(filler.end - 0.8) < 0.001)
        #expect(filler.label == "um")
    }

    @Test("Every filler spelling is recognised", arguments: ["um", "Um", "uh,", "Erm.", "ah", "hmm"])
    func fillerSpellings(spelling: String) {
        let script = transcript([word("So", 0, 0.4), word(spelling, 0.5, 0.8), word("here", 0.9, 1.3)])
        #expect(planner.cuts(for: script, duration: 2).contains { $0.reason == .fillerWord })
    }

    /// Every addition to the list is a word somebody uses deliberately in some sentence. A
    /// planner that removes "like" from "it works like this" is worse than one that leaves
    /// a few "um"s in.
    @Test("Ordinary words are never proposed", arguments: ["like", "so", "well", "right", "actually"])
    func ordinaryWordsAreKept(ordinary: String) {
        let script = transcript([word("It", 0, 0.3), word(ordinary, 0.35, 0.6), word("works", 0.65, 1)])
        #expect(!planner.cuts(for: script, duration: 2).contains { $0.reason == .fillerWord })
    }

    @Test("Fillers can be turned off")
    func fillersCanBeDisabled() {
        let planner = TranscriptCutPlanner(removesFillers: false)
        let script = transcript([word("So", 0, 0.4), word("um", 0.5, 0.8)])
        #expect(!planner.cuts(for: script, duration: 1).contains { $0.reason == .fillerWord })
    }

    // MARK: - Silences

    @Test("A long pause is proposed for removal")
    func longPauseIsCut() throws {
        let script = transcript([word("Before", 0, 1), word("after", 4, 5)])
        let silence = try #require(planner.cuts(for: script, duration: 6).first { $0.reason == .silence })
        #expect(silence.duration > 1)
    }

    /// Shorter pauses are how speech is punctuated; removing them makes a person sound
    /// like they are reading a list.
    @Test("A short pause is left alone")
    func shortPauseIsKept() {
        let script = transcript([word("Before", 0, 1), word("after", 1.5, 2)])
        #expect(!planner.cuts(for: script, duration: 3).contains { $0.reason == .silence })
    }

    /// The whole trick: the cut starts after the previous word ends and finishes before
    /// the next begins, so what is removed is entirely silence.
    @Test("A silence cut never touches the words either side")
    func cutsBiteIntoSilenceOnly() throws {
        let script = transcript([word("Before", 0, 1), word("after", 4, 5)])
        let silence = try #require(planner.cuts(for: script, duration: 6).first { $0.reason == .silence })

        #expect(silence.start > 1, "the cut starts after the previous word ends")
        #expect(silence.end < 4, "and finishes before the next one begins")
    }

    @Test("Padding is left at both ends", arguments: [0.2, 0.35, 0.6])
    func paddingIsSymmetric(padding: TimeInterval) throws {
        let planner = TranscriptCutPlanner(silencePadding: padding)
        let script = transcript([word("Before", 0, 1), word("after", 5, 6)])
        let silence = try #require(planner.cuts(for: script, duration: 7).first { $0.reason == .silence })

        #expect(abs(silence.start - (1 + padding)) < 0.001)
        #expect(abs(silence.end - (5 - padding)) < 0.001)
    }

    /// Silence after the last word is the most common thing left in an unedited recording.
    @Test("Silence at the end is proposed too")
    func trailingSilence() throws {
        let script = transcript([word("Done", 0, 1)])
        let cuts = planner.cuts(for: script, duration: 10)
        let tail = try #require(cuts.last)
        #expect(tail.reason == .silence)
        #expect(abs(tail.end - 10) < 0.001)
    }

    @Test("Silence at the start is proposed")
    func leadingSilence() {
        let script = transcript([word("Late", 5, 6)])
        let cuts = planner.cuts(for: script, duration: 7)
        #expect(cuts.contains { $0.reason == .silence && $0.start < 5 })
    }

    @Test("Silences can be turned off")
    func silencesCanBeDisabled() {
        let planner = TranscriptCutPlanner(removesSilences: false)
        let script = transcript([word("Before", 0, 1), word("after", 5, 6)])
        #expect(!planner.cuts(for: script, duration: 7).contains { $0.reason == .silence })
    }

    // MARK: - Overlaps

    /// A filler word inside a pause produces two proposals for one stretch of audio, and
    /// applying both would remove the same range twice.
    @Test("Overlapping proposals are merged")
    func overlapsAreMerged() {
        let script = transcript([
            word("Before", 0, 1),
            word("um", 3, 3.3),
            word("after", 6, 7)
        ])
        let cuts = planner.cuts(for: script, duration: 8)

        for (index, cut) in cuts.enumerated() {
            for other in cuts[(index + 1)...] {
                #expect(!cut.range.overlaps(other.range), "\(cut) overlaps \(other)")
            }
        }
    }

    @Test("Cuts come back in order")
    func cutsAreOrdered() {
        let script = transcript([
            word("um", 0.1, 0.4),
            word("Before", 1, 2),
            word("uh", 5, 5.3),
            word("after", 9, 10)
        ])
        let cuts = planner.cuts(for: script, duration: 12)
        #expect(cuts.map(\.start) == cuts.map(\.start).sorted())
    }

    // MARK: - Applying

    /// The planner proposes and the timeline disposes: cuts become clip boundaries, which
    /// are undoable and non-destructive like every other edit.
    @Test("Applying cuts produces a shorter timeline")
    func applyingCuts() {
        let script = transcript([word("Before", 0, 1), word("after", 5, 6)])
        let cuts = planner.cuts(for: script, duration: 7)
        let timeline = planner.applying(cuts, to: 7)

        #expect(timeline.editedDuration < 7)
        #expect(timeline.clips.count >= 2)
    }

    @Test("What survives is what was not cut")
    func survivingFootage() throws {
        let cuts = [ProposedCut(start: 2, end: 4, reason: .silence, label: "pause")]
        let timeline = planner.applying(cuts, to: 10)

        #expect(abs(timeline.editedDuration - 8) < 0.001)
        // The moment at edited-time 2 is source-time 4: the cut is gone.
        #expect(try abs(#require(timeline.sourceTime(forEdited: 2)) - 4) < 0.001)
        #expect(timeline.editedTime(forSource: 3) == nil, "the cut moment has no place")
    }

    @Test("No cuts leaves the whole recording")
    func noCuts() {
        let timeline = planner.applying([], to: 10)
        #expect(abs(timeline.editedDuration - 10) < 0.001)
        #expect(timeline.clips.count == 1)
    }

    @Test("A cut covering everything leaves nothing")
    func cutEverything() {
        let timeline = planner.applying(
            [ProposedCut(start: 0, end: 10, reason: .silence, label: "all")],
            to: 10
        )
        #expect(timeline.editedDuration == 0)
    }

    // MARK: - Degenerate input

    @Test("An empty transcript proposes nothing")
    func emptyTranscript() {
        #expect(planner.cuts(for: Transcript(), duration: 10).isEmpty)
    }

    @Test("A transcript of nothing but fillers still leaves a usable timeline")
    func allFillers() {
        let script = transcript([word("um", 0, 0.3), word("uh", 0.5, 0.8)])
        let cuts = planner.cuts(for: script, duration: 1)
        let timeline = planner.applying(cuts, to: 1)
        #expect(timeline.editedDuration >= 0)
    }

    @Test("Words arrive sorted however they were given")
    func wordsAreSorted() {
        let script = Transcript(words: [
            TranscriptWord(text: "second", start: 5, end: 6),
            TranscriptWord(text: "first", start: 0, end: 1)
        ])
        #expect(script.words.map(\.text) == ["first", "second"])
    }

    @Test("A word that ends before it starts is repaired rather than trusted")
    func backwardsWord() {
        let word = TranscriptWord(text: "odd", start: 5, end: 1)
        #expect(word.end >= word.start)
        #expect(word.duration >= 0)
    }

    @Test("A transcript round-trips")
    func roundTrips() throws {
        let script = transcript([word("Hello", 0, 0.5), word("world", 0.6, 1.2)])
        let data = try JSONEncoder().encode(script)
        #expect(try JSONDecoder().decode(Transcript.self, from: data) == script)
    }

    @Test("A transcript with nothing in it at all decodes")
    func emptyObject() throws {
        #expect(try JSONDecoder().decode(Transcript.self, from: Data("{}".utf8)).isEmpty)
    }

    /// The same transcript always proposes the same cuts, so a review list is stable
    /// between openings rather than reshuffling.
    @Test("Planning is deterministic")
    func deterministic() {
        let script = transcript([word("So", 0, 0.4), word("um", 0.5, 0.8), word("here", 4, 5)])
        let first = planner.cuts(for: script, duration: 7)
        let second = planner.cuts(for: script, duration: 7)

        #expect(first.map(\.start) == second.map(\.start))
        #expect(first.map(\.end) == second.map(\.end))
        #expect(first.map(\.label) == second.map(\.label))
    }
}
