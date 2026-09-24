import CoreGraphics
import Foundation
import Shared
import StudioSession
import Testing
@testable import StudioRender

/// Silence in a screen recording is often the content (docs/17 T-STU-6).
///
/// The stretch where nobody speaks and the pointer walks through a menu is the
/// demonstration, so a pause is only cut where nothing happened on screen, is shortened
/// rather than deleted, and is planned from the narrator's words alone.
@Suite("Transcript cut protection")
struct TranscriptCutProtectionTests {
    private let planner = TranscriptCutPlanner()

    private func word(
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        track: SpeechTrackKind = .mixed
    ) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end, track: track)
    }

    @Test("A long pause is shortened to about half a second, not removed")
    func pauseIsShortened() throws {
        let script = Transcript(words: [word("Hello", 0, 1), word("again", 5, 6)])
        let cut = try #require(planner.cuts(for: script, duration: 6).first)
        let kept = 4 - cut.duration
        #expect(abs(kept - 0.5) < 0.01, "kept \(kept) s of a 4 s pause")
    }

    @Test("A pause where the user clicked or typed is not cut there", arguments: [
        InputTelemetry(clicks: [ClickEvent(time: 3, position: .zero)]),
        InputTelemetry(keystrokes: [KeystrokeEvent(time: 3, caption: "⌘S")])
    ])
    func activityIsProtected(telemetry: InputTelemetry) {
        let script = Transcript(words: [word("Hello", 0, 1), word("again", 5, 6)])
        let protected = TranscriptCutPlanner.activityRanges(in: telemetry)
        let cuts = planner.cuts(for: script, duration: 6, protecting: protected)
        #expect(cuts.allSatisfy { !$0.range.contains(3) })
        // The quiet stretches either side of the click are still offered.
        #expect(!cuts.isEmpty)
    }

    @Test("Pointer travel protects the stretch it covers; a resting hand does not")
    func pointerTravel() {
        let moving = InputTelemetry(pointer: [
            PointerSample(time: 2, position: CGPoint(x: 0, y: 0)),
            PointerSample(time: 3, position: CGPoint(x: 200, y: 0)),
            PointerSample(time: 4, position: CGPoint(x: 400, y: 0))
        ])
        let resting = InputTelemetry(pointer: [
            PointerSample(time: 2, position: CGPoint(x: 0, y: 0)),
            PointerSample(time: 3, position: CGPoint(x: 1, y: 0)),
            PointerSample(time: 4, position: CGPoint(x: 2, y: 1))
        ])
        let script = Transcript(words: [word("Hello", 0, 1), word("again", 6, 7)])

        let guarded = planner.cuts(
            for: script,
            duration: 7,
            protecting: TranscriptCutPlanner.activityRanges(in: moving)
        )
        #expect(guarded.allSatisfy { $0.range.upperBound <= 1.6 || $0.range.lowerBound >= 4.4 })

        let open = planner.cuts(
            for: script,
            duration: 7,
            protecting: TranscriptCutPlanner.activityRanges(in: resting)
        )
        #expect(open.count == 1)
    }

    @Test("Filler words and pauses can be planned separately")
    func separateToggles() {
        let script = Transcript(words: [word("um", 0, 0.3), word("Hello", 0.4, 1), word("again", 5, 6)])
        let fillers = TranscriptCutPlanner(removesSilences: false).cuts(for: script, duration: 6)
        let pauses = TranscriptCutPlanner(removesFillers: false).cuts(for: script, duration: 6)
        #expect(fillers.allSatisfy { $0.reason == .fillerWord } && !fillers.isEmpty)
        #expect(pauses.allSatisfy { $0.reason == .silence } && !pauses.isEmpty)
    }

    @Test("Only the narrator's words plan cuts, never recorded system audio")
    func systemAudioIsNotCut() {
        let script = Transcript(words: [
            word("Hello", 0, 1, track: .microphone),
            word("um", 2, 2.3, track: .system),
            word("again", 2.5, 3, track: .microphone)
        ])
        let cuts = planner.cuts(for: script, duration: 3)
        #expect(!cuts.contains { $0.reason == .fillerWord })
        let systemOnly = Transcript(words: [word("um", 0, 0.3, track: .system)])
        #expect(planner.cuts(for: systemOnly, duration: 10).isEmpty)
    }

    @Test("Subtracting protection", arguments: [
        // (cut, protected, expected pieces)
        ((2.0, 8.0), [(4.0, 5.0)], [(2.0, 4.0), (5.0, 8.0)]),
        ((2.0, 8.0), [(1.0, 9.0)], []),
        ((2.0, 8.0), [(2.1, 7.9)], []),
        ((2.0, 8.0), [(9.0, 10.0)], [(2.0, 8.0)])
    ])
    func subtraction(
        cut: (Double, Double),
        protected: [(Double, Double)],
        expected: [(Double, Double)]
    ) {
        let pieces = TranscriptCutPlanner.subtracting(
            protected.map { $0.0 ... $0.1 },
            from: ProposedCut(start: cut.0, end: cut.1, reason: .silence, label: "pause")
        )
        #expect(pieces.map(\.start) == expected.map(\.0))
        #expect(pieces.map(\.end) == expected.map(\.1))
    }
}
