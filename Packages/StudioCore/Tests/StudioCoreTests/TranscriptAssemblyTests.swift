import Foundation
import Testing
@testable import StudioCore

/// Splitting a timed run of recognised text into words (docs/09 U3.6).
///
/// `SpeechAnalyzer` reports attributed runs that sometimes cover a whole phrase, and the
/// planner needs a word at a time. Testable here because it is arithmetic on strings —
/// no microphone, no model, no particular version of macOS.
@Suite("Transcript assembly")
struct TranscriptAssemblyTests {
    // MARK: - Splitting

    @Test("A single word keeps the run's whole span")
    func singleWord() throws {
        let words = TranscriptAssembly.words(in: "hello", start: 1, end: 2)
        let word = try #require(words.first)
        #expect(words.count == 1)
        #expect(word.text == "hello")
        #expect(word.start == 1)
        #expect(word.end == 2)
    }

    @Test("A phrase becomes one word per token")
    func phraseSplits() {
        let words = TranscriptAssembly.words(in: "one two three", start: 0, end: 3)
        #expect(words.map(\.text) == ["one", "two", "three"])
    }

    @Test("The words stay inside the run and in order")
    func staysInsideTheRun() {
        let words = TranscriptAssembly.words(in: "the quick brown fox", start: 10, end: 12)
        #expect(words.allSatisfy { $0.start >= 10 && $0.end <= 12 })
        for (earlier, later) in zip(words, words.dropFirst()) {
            #expect(earlier.end <= later.start, "a word may not start before the one before it ends")
        }
    }

    /// Apportioning by character count is what makes a long word occupy more of the run
    /// than a short one — the alternative, splitting the span evenly, would give "a" and
    /// "extraordinarily" the same duration.
    @Test("A longer word gets a longer share of the run")
    func longerWordsGetLongerShares() throws {
        let words = TranscriptAssembly.words(in: "a extraordinarily", start: 0, end: 10)
        let short = try #require(words.first)
        let long = try #require(words.last)
        #expect(long.end - long.start > short.end - short.start)
    }

    @Test("Repeated and leading whitespace does not produce empty words")
    func whitespaceIsNotAWord() {
        let words = TranscriptAssembly.words(in: "   one\t\ttwo  \n", start: 0, end: 2)
        #expect(words.map(\.text) == ["one", "two"])
        #expect(words.allSatisfy { !$0.text.isEmpty })
    }

    /// A run of pure whitespace has to vanish rather than become a zero-length word: a word
    /// sitting in the middle of a pause would stop the planner proposing the cut at all.
    @Test("A whitespace-only run produces nothing", arguments: ["", " ", "\n\t  "])
    func whitespaceOnly(text: String) {
        #expect(TranscriptAssembly.words(in: text, start: 0, end: 1).isEmpty)
    }

    // MARK: - Degenerate spans

    @Test("A zero-length run still reports its words")
    func zeroDuration() {
        let words = TranscriptAssembly.words(in: "one two", start: 4, end: 4)
        #expect(words.map(\.text) == ["one", "two"])
        #expect(words.allSatisfy { $0.start == 4 && $0.end == 4 })
    }

    @Test("A backwards run is treated as an instant rather than producing negative times")
    func backwardsRun() {
        let words = TranscriptAssembly.words(in: "one two", start: 5, end: 3)
        #expect(words.allSatisfy { $0.start == 5 && $0.end == 5 })
    }

    // MARK: - Punctuation

    /// Splitting on whitespace rather than by word boundaries: word enumeration would
    /// report "don" and "t" for "don't", and the planner would then see a word it has
    /// no time for.
    @Test("An apostrophe does not split a word")
    func apostrophe() {
        #expect(TranscriptAssembly.words(in: "don't", start: 0, end: 1).map(\.text) == ["don't"])
    }

    @Test("Trailing punctuation stays attached")
    func punctuationStaysAttached() {
        #expect(TranscriptAssembly.words(in: "hello, world.", start: 0, end: 1).map(\.text) == ["hello,", "world."])
    }

    // MARK: - Feeding the planner

    /// The end-to-end shape: an analyzer-style phrase run, split, then planned over. The
    /// filler in the middle has to come out with a cut that only covers the filler.
    @Test("A split run plans the same cuts as per-word input")
    func splitRunPlansCorrectly() throws {
        let phrase = TranscriptAssembly.words(in: "we um ship", start: 0, end: 9)
        let cuts = TranscriptCutPlanner().cuts(for: Transcript(words: phrase), duration: 9)
        let filler = try #require(cuts.first { $0.reason == ProposedCut.Reason.fillerWord })
        let um = try #require(phrase.first { $0.text == "um" })
        #expect(filler.range.lowerBound <= um.start)
        #expect(filler.range.upperBound >= um.end)
    }
}
