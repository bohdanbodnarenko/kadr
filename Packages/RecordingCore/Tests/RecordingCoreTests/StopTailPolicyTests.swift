import Foundation
import Testing
@testable import RecordingCore

/// What comes off the end of a recording when the user walks to the Stop button
/// (docs/03 §1.8).
///
/// This decides what is *not written to the file*, so every rule that keeps it from eating
/// somebody's recording is a test rather than a comment. The asymmetry is deliberate
/// throughout: an extra second of a travelling pointer is untidy, three words cut off the
/// end of a sentence is the recording being useless.
@Suite("Stop tail")
struct StopTailPolicyTests {
    struct Case {
        let name: String
        let travel: TimeInterval?
        let duration: TimeInterval
        let expected: TimeInterval
    }

    @Test("With nothing else going on, the trim is the trip to the button", arguments: [
        Case(name: "a hotkey stop trims nothing", travel: nil, duration: 60, expected: 0),
        Case(name: "a click where the pointer already was trims nothing", travel: 0.05, duration: 60, expected: 0),
        Case(name: "the usual trip comes off", travel: 1.1, duration: 60, expected: 1.1),
        Case(name: "resting on the controls is not travel", travel: 45, duration: 120, expected: 2.5),
        Case(name: "at the floor, nothing", travel: 0.19, duration: 60, expected: 0),
        Case(name: "just past the floor, all of it", travel: 0.21, duration: 60, expected: 0.21)
    ])
    func travelAlone(_ testCase: Case) {
        let tail = StopTailPolicy.tail(travel: testCase.travel, duration: testCase.duration)
        #expect(abs(tail - testCase.expected) < 0.0001, "\(testCase.name)")
    }

    // MARK: - Content takes its time back

    /// "…and that's it, thanks!" — said while reaching for Stop. Cutting the trip here cuts
    /// the sentence, which is the whole point of the recording.
    @Test("Nothing is cut over someone still talking")
    func speechProtectsTheEnding() {
        let tail = StopTailPolicy.tail(
            travel: 2,
            content: .init(lastAudible: 59.8),
            duration: 60
        )

        #expect(tail == 0)
    }

    @Test("A sentence that ended a moment ago keeps its last consonant")
    func speechKeepsItsGrace() {
        // Audio stopped at 58.5, so 58.9 is the earliest the file may end.
        let tail = StopTailPolicy.tail(
            travel: 2,
            content: .init(lastAudible: 58.5),
            duration: 60
        )

        #expect(abs(tail - 1.1) < 0.0001)
        #expect(60 - tail >= 58.5 + StopTailPolicy.audioGrace - 0.0001)
    }

    /// The second after a click is the result of the click, which is the thing worth showing.
    @Test("A click on the way to Stop keeps what it did on screen")
    func inputKeepsItsResult() {
        let tail = StopTailPolicy.tail(
            travel: 2.5,
            content: .init(lastInput: 59.4),
            duration: 60
        )

        #expect(tail == 0, "the click's result had not finished appearing")
    }

    @Test("Silence and stillness leave the whole trip trimmable")
    func quietEndingTrimsFully() {
        let tail = StopTailPolicy.tail(
            travel: 1.8,
            content: .init(lastInput: 40, lastAudible: 41),
            duration: 60
        )

        #expect(abs(tail - 1.8) < 0.0001)
    }

    @Test("The latest signal wins, whichever kind it is")
    func latestSignalWins() {
        // Typing stopped long ago; the talking did not.
        let talking = StopTailPolicy.tail(
            travel: 2,
            content: .init(lastInput: 30, lastAudible: 59.5),
            duration: 60
        )
        #expect(talking == 0)

        // And the other way round.
        let clicking = StopTailPolicy.tail(
            travel: 2,
            content: .init(lastInput: 59.5, lastAudible: 30),
            duration: 60
        )
        #expect(clicking == 0)
    }

    /// Content only ever gives time back: a recording silent for a minute is not more
    /// trimmable than the trip to the button.
    @Test("Content can shorten the trim but never lengthen it", arguments: [0.0, 10.0, 30.0, 55.0])
    func contentNeverLengthens(lastMoment: TimeInterval) {
        let tail = StopTailPolicy.tail(
            travel: 1.2,
            content: .init(lastInput: lastMoment, lastAudible: lastMoment),
            duration: 60
        )

        #expect(tail <= 1.2 + 0.0001)
    }

    // MARK: - Floors

    /// A four-second take stopped after a long hunt keeps its first second rather than
    /// becoming an empty file.
    @Test("A short recording keeps a second of itself", arguments: [1.2, 1.5, 2.0, 3.0])
    func shortRecordingsKeepAFloor(duration: TimeInterval) {
        let tail = StopTailPolicy.tail(travel: 2.5, duration: duration)

        #expect(duration - tail >= StopTailPolicy.minimumRemaining - 0.0001)
        #expect(tail >= 0)
    }

    @Test("A recording shorter than the floor is never trimmed", arguments: [0.0, 0.4, 1.0])
    func nothingToTrim(duration: TimeInterval) {
        #expect(StopTailPolicy.tail(travel: 2, duration: duration) == 0)
    }

    @Test("However long the hunt, the cut is bounded")
    func boundedAbove() {
        #expect(StopTailPolicy.tail(travel: 600, duration: 600) == StopTailPolicy.maximumTail)
    }

    /// Whatever the evidence says, the result is a trim of nothing or a trim worth making —
    /// never a tenth of a second that costs a re-encode and changes nothing anyone can see.
    @Test("A trim shrunk below the floor becomes no trim at all")
    func shrunkToNothing() {
        // Audio ended at 59.5, so its grace allows a tenth of a second — which is not a
        // trim, it is a rounding error that costs a re-encode and changes nothing anyone
        // can see.
        let barelyAnything = StopTailPolicy.tail(
            travel: 1.5,
            content: .init(lastAudible: 59.5),
            duration: 60
        )
        #expect(barelyAnything == 0)

        // A fifth of a second earlier and there is something worth cutting.
        let worthIt = StopTailPolicy.tail(
            travel: 1.5,
            content: .init(lastAudible: 59.3),
            duration: 60
        )
        #expect(abs(worthIt - 0.3) < 0.0001)
    }
}
