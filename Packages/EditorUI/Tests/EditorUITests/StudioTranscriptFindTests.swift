import Foundation
import StudioRender
import StudioSession
import Testing
@testable import EditorUI

/// Find in place, and filler words by language (docs/18 STU-10).
@Suite("Transcript find and fillers")
struct StudioTranscriptFindTests {
    private let transcript = Transcript(words: [
        TranscriptWord(text: "Open", start: 0, end: 0.4),
        TranscriptWord(text: "the", start: 0.5, end: 0.7),
        TranscriptWord(text: "Café", start: 0.8, end: 1.2),
        TranscriptWord(text: "menu,", start: 1.3, end: 1.7),
        TranscriptWord(text: "then", start: 1.8, end: 2.0),
        TranscriptWord(text: "the", start: 2.1, end: 2.3),
        TranscriptWord(text: "menu", start: 2.4, end: 2.8)
    ])

    @Test("A search finds matches in order and hides nothing", arguments: [
        ("menu", 2),
        ("THE", 3),
        ("cafe", 1),
        ("  ", 0),
        ("absent", 0)
    ])
    func matches(query: String, count: Int) {
        let ids = StudioDocumentModel.matchingWordIDs(in: transcript, query: query)
        #expect(ids.count == count)
        let order = transcript.words.map(\.id)
        #expect(ids == order.filter(ids.contains), "matches must keep transcript order")
    }

    @Test("Filler words exist only for languages Kadr knows", arguments: [
        ("", true),
        ("en_US", true),
        ("de_DE", true),
        ("fr_FR", true),
        ("uk_UA", false),
        ("ja_JP", false)
    ])
    func fillerLanguages(locale: String, known: Bool) {
        #expect((TranscriptCutPlanner.fillerWords(forLocale: locale) != nil) == known)
    }

    @Test("A Ukrainian transcript proposes no filler cuts")
    func noFillerCutsWithoutAList() {
        let words = [
            TranscriptWord(text: "um", start: 0, end: 0.3),
            TranscriptWord(text: "привіт", start: 0.4, end: 0.9)
        ]
        let planner = TranscriptCutPlanner(removesSilences: false)
        let english = planner.cuts(for: Transcript(words: words, localeIdentifier: "en_US"), duration: 1)
        let ukrainian = planner.cuts(for: Transcript(words: words, localeIdentifier: "uk_UA"), duration: 1)
        #expect(!english.isEmpty)
        #expect(ukrainian.isEmpty)
    }
}
