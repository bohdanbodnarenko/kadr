import Foundation
import Testing
@testable import StudioSession

@Suite("Caption export")
struct CaptionExportTests {
    @Test("SRT has numbered cues and comma milliseconds")
    func srtFormat() {
        let transcript = Transcript(words: [
            TranscriptWord(text: "Hello", start: 0, end: 0.4),
            TranscriptWord(text: "world.", start: 0.5, end: 1.0)
        ])
        let srt = CaptionExport.srt(from: transcript, timeline: .whole(duration: 2))
        #expect(srt.contains("1\n"))
        #expect(srt.contains("00:00:00,000"))
        #expect(srt.contains("Hello"))
    }

    @Test("VTT starts with WEBVTT")
    func vttFormat() {
        let transcript = Transcript(words: [
            TranscriptWord(text: "Hi", start: 1, end: 1.5)
        ])
        let vtt = CaptionExport.vtt(from: transcript, timeline: .whole(duration: 3))
        #expect(vtt.hasPrefix("WEBVTT"))
        #expect(vtt.contains("00:00:01.000"))
    }

    @Test("Words in a cut do not appear in the captions")
    func cutWordsAreDropped() {
        let transcript = Transcript(words: [
            TranscriptWord(text: "Keep", start: 0, end: 1),
            TranscriptWord(text: "Gone", start: 2, end: 3),
            TranscriptWord(text: "Also", start: 4, end: 5)
        ])
        let timeline = ClipTimeline(clips: [
            Clip(sourceStart: 0, sourceDuration: 1),
            Clip(sourceStart: 4, sourceDuration: 1)
        ])
        let srt = CaptionExport.srt(from: transcript, timeline: timeline)
        #expect(srt.contains("Keep"))
        #expect(!srt.contains("Gone"))
        #expect(srt.contains("Also"))
    }

    @Test("The live word is the one whose interval covers the playhead")
    func karaokePicksTheSpokenWord() {
        let transcript = Transcript(words: [
            TranscriptWord(text: "Hello", start: 0, end: 0.4),
            TranscriptWord(text: "world.", start: 0.5, end: 1.0)
        ])
        let timeline = ClipTimeline.whole(duration: 2)
        let duringHello = CaptionExport.cue(from: transcript, timeline: timeline, at: 0.2)
        #expect(duringHello?.highlight == "Hello")
        #expect(duringHello?.activeIndex == 0)
        #expect(duringHello?.spokenCount == 0)

        let between = CaptionExport.cue(from: transcript, timeline: timeline, at: 0.45)
        #expect(between?.highlight == nil)
        #expect(between?.activeIndex == nil)
        #expect(between?.spokenCount == 1)

        let duringWorld = CaptionExport.cue(from: transcript, timeline: timeline, at: 0.7)
        #expect(duringWorld?.highlight == "world.")
        #expect(duringWorld?.activeIndex == 1)
        #expect(duringWorld?.spokenCount == 1)
    }
}

@Suite("Transcript post-processing")
struct TranscriptPostProcessorTests {
    @Test("Bracketed asides and tags are stripped")
    func stripsHallucinations() {
        #expect(TranscriptPostProcessor.cleaned("[BLANK_AUDIO] hello") == "hello")
        #expect(TranscriptPostProcessor.cleaned("(upbeat music) hi") == "hi")
        #expect(TranscriptPostProcessor.cleaned("<s>word</s>").isEmpty)
    }

    @Test("A repetition loop is shortened, not left as a dozen copies")
    func dropsRepetitionLoops() {
        let words = (0 ..< 8).map { TranscriptWord(text: "the", start: Double($0), end: Double($0) + 0.2) }
        let processed = TranscriptPostProcessor().processed(Transcript(words: words))
        #expect(processed.words.count < 8)
        #expect(processed.words.count >= 2)
    }

    @Test("Spaced replacement is whole-word, not substring")
    func spacedReplacement() {
        let text = TranscriptPostProcessor.replacing(in: "catalogue cat", using: ["cat": "dog"])
        #expect(text.contains("catalogue"))
        #expect(text.contains("dog"))
        #expect(!text.contains("dogalogue"))
    }

    @Test("A collapsed transcript is detected")
    func collapsedTimestamps() {
        let transcript = Transcript(words: [
            TranscriptWord(text: "a", start: 0, end: 0.1),
            TranscriptWord(text: "b", start: 0.1, end: 0.2)
        ])
        #expect(transcript.timingsLookCollapsed(relativeTo: 600))
        #expect(!transcript.spanLooksPlausible(relativeTo: 600))
    }
}

@Suite("Speech language repair")
struct SpeechLanguageTests {
    @Test("An unsupported regional variant falls back to the same language")
    func regionalFallback() {
        let resolved = SpeechLanguage.resolved("en_GB", supported: ["en_US", "de_DE"])
        #expect(resolved.hasPrefix("en"))
    }

    @Test("An empty stored value uses the current locale")
    func emptyMeansCurrent() {
        #expect(!SpeechLanguage.currentIdentifier("").isEmpty)
    }
}

@Suite("Hypothesis agreement")
struct HypothesisAgreementTests {
    @Test("A word has to survive two hypotheses before it is confirmed")
    func requiresAgreement() {
        var engine = HypothesisAgreement()
        #expect(engine.confirmed(from: ["hello", "world"]).isEmpty)
        let second = engine.confirmed(from: ["hello", "there"])
        #expect(second == ["hello"])
    }

    @Test("A retraction does not confirm the dropped tail")
    func retraction() {
        var engine = HypothesisAgreement()
        _ = engine.confirmed(from: ["one", "two", "three"])
        let next = engine.confirmed(from: ["one", "two"])
        #expect(next == ["one", "two"])
    }
}

@Suite("Chapter marks")
struct ChapterMarksTests {
    @Test("A long pause becomes a chapter")
    func pauseBecomesChapter() {
        let transcript = Transcript(words: [
            TranscriptWord(text: "Intro", start: 0, end: 1),
            TranscriptWord(text: "Later", start: 8, end: 9)
        ])
        let marks = ChapterMarks.marks(from: transcript, duration: 10)
        #expect(marks.count >= 2)
        #expect(marks.contains { abs($0.time - 8) < 0.01 })
    }
}
