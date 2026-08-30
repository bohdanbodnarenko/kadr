import Foundation
import Testing
@testable import StudioSession

/// Splitting a script into something a prompter can draw and follow (docs/08).
@Suite("Teleprompter script")
struct TeleprompterScriptTests {
    // MARK: - Splitting

    @Test("A script splits into words and keeps them as written")
    func splitsIntoWords() {
        let script = TeleprompterScript(text: "Hello there, world!")
        #expect(script.words.map(\.text) == ["Hello", "there,", "world!"])
    }

    /// Drawn text keeps its punctuation and capitals; compared text does not. The reader
    /// sees what they wrote, and the matcher sees what a recogniser could plausibly say.
    @Test("Words carry a normalised form alongside the written one")
    func normalisedAlongside() {
        let script = TeleprompterScript(text: "Hello there, World!")
        #expect(script.words.map(\.normalized) == ["hello", "there", "world"])
    }

    @Test("Lines are the author's, not the renderer's")
    func linesAreAuthored() {
        let script = TeleprompterScript(text: "First line\nSecond line")
        #expect(script.lines.count == 2)
        #expect(script.lines[0].text == "First line")
        #expect(script.lines[1].wordRange == 2 ..< 4)
    }

    /// A blank line is how somebody spaced their script out, and closing the gap re-flows
    /// the reading they rehearsed against.
    @Test("Blank lines survive")
    func blankLinesSurvive() {
        let script = TeleprompterScript(text: "One\n\nTwo")
        #expect(script.lines.count == 3)
        #expect(script.lines[1].text.isEmpty)
        #expect(script.lines[1].wordRange.isEmpty)
    }

    @Test("A word knows which line it is on")
    func wordsKnowTheirLine() {
        let script = TeleprompterScript(text: "One two\nthree")
        #expect(script.words.map(\.line) == [0, 0, 1])
        #expect(script.line(ofWord: 2) == 1)
    }

    @Test("An empty script is empty rather than a crash waiting to happen")
    func emptyScript() {
        let script = TeleprompterScript(text: "")
        #expect(script.isEmpty)
        #expect(script.line(ofWord: 5) == 0)
        #expect(script.progress(atWord: 3) == 0)
    }

    @Test("Runs of whitespace do not become empty words")
    func whitespaceRuns() {
        let script = TeleprompterScript(text: "  One   two  ")
        #expect(script.words.map(\.text) == ["One", "two"])
    }

    // MARK: - Normalising

    /// Digits stay. A stricter filter would drop the "26" from "macOS 26" — which is
    /// exactly the word that says where in the script somebody is.
    @Test(
        "Normalising keeps what identifies a word",
        arguments: [
            ("Hello,", "hello"),
            ("macOS", "macos"),
            ("26", "26"),
            ("don't", "don't"),
            ("“quoted”", "quoted"),
            ("well-known", "wellknown"),
            ("...", "")
        ]
    )
    func normalising(input: String, expected: String) {
        #expect(TeleprompterScript.normalize(input) == expected)
    }

    // MARK: - Progress

    @Test("Progress runs from nothing to everything")
    func progress() {
        let script = TeleprompterScript(text: "one two three four five")
        #expect(script.progress(atWord: 0) == 0)
        #expect(script.progress(atWord: 4) == 1)
        #expect(script.progress(atWord: 99) == 1)
        #expect(script.progress(atWord: -5) == 0)
    }

    // MARK: - Pacing

    @Test("A steady rate advances a word at a time")
    func pacing() {
        let pacing = TeleprompterPacing(wordsPerMinute: 120)
        #expect(pacing.position(after: 60) == 120)
        #expect(pacing.position(after: 30) == 60)
        #expect(pacing.position(after: 0) == 0)
    }

    /// Fractional on purpose: the panel scrolls continuously, and rounding here would make
    /// it step a word at a time, which reads as a stutter.
    @Test("The position between words is fractional")
    func pacingIsContinuous() {
        let pacing = TeleprompterPacing(wordsPerMinute: 60)
        #expect(pacing.position(after: 0.5) == 0.5)
    }

    @Test("Time before the start does not run the script backwards")
    func negativeTime() {
        #expect(TeleprompterPacing().position(after: -10) == 0)
    }

    @Test("A rate outside the usable range is brought into it", arguments: [0.0, 10.0, 1000.0])
    func rateIsClamped(requested: Double) {
        let pacing = TeleprompterPacing(wordsPerMinute: requested)
        #expect(pacing.wordsPerMinute >= TeleprompterPacing.slowest)
        #expect(pacing.wordsPerMinute <= TeleprompterPacing.fastest)
    }

    @Test("A script's reading time follows its length")
    func duration() {
        let script = TeleprompterScript(text: Array(repeating: "word", count: 240).joined(separator: " "))
        #expect(TeleprompterPacing(wordsPerMinute: 120).duration(of: script) == 120)
    }

    // MARK: - Round-tripping

    /// Scripts are saved with the recording settings, so a prompter opened tomorrow shows
    /// what was written today.
    @Test("A script survives being saved and read back")
    func codable() throws {
        let script = TeleprompterScript(text: "Hello there\nSecond line")
        let data = try JSONEncoder().encode(script)
        let decoded = try JSONDecoder().decode(TeleprompterScript.self, from: data)
        #expect(decoded == script)
    }
}
