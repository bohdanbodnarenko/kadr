import Foundation
import Testing
@testable import StudioSession

/// Correcting what the speech engine heard (docs/18 Phase 4).
@Suite("Transcript corrections")
struct TranscriptCorrectionTests {
    private let hello = TranscriptWord(text: "helo", start: 0, end: 0.4)
    private let world = TranscriptWord(text: "world", start: 0.5, end: 0.9)

    private var transcript: Transcript {
        var transcript = Transcript()
        transcript.words = [hello, world]
        return transcript
    }

    @Test("A correction replaces the word's text and keeps its timing")
    func applies() {
        let corrected = transcript.applying(corrections: [hello.id: "hello"])
        #expect(corrected.words.map(\.text) == ["hello", "world"])
        #expect(corrected.words[0].start == hello.start)
        #expect(corrected.words[0].end == hello.end)
    }

    @Test("A blank correction keeps the word", arguments: ["", "   "])
    func blankIgnored(text: String) {
        #expect(transcript.applying(corrections: [hello.id: text]).words[0].text == "helo")
    }

    @Test("Correcting to what was heard, or to nothing, clears the correction", arguments: ["helo", "", " "])
    func clears(text: String) {
        var edit = StudioEdit()
        edit.correct(hello, to: "hello")
        #expect(edit.transcriptCorrections[hello.id] == "hello")
        edit.correct(hello, to: text)
        #expect(edit.transcriptCorrections[hello.id] == nil)
    }

    @Test("Captions carry the correction")
    func captions() {
        let corrected = transcript.applying(corrections: [hello.id: "hello"])
        let srt = CaptionExport.srt(from: corrected, timeline: .whole(duration: 2))
        #expect(srt.contains("hello world"))
    }
}
