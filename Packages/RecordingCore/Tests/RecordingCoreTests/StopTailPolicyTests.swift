import Foundation
import Testing
@testable import RecordingCore

/// What comes off the end of a recording when the user walks to the Stop button
/// (docs/03 §1.8).
///
/// This decides what is *not written to the file*, so every rule that keeps it from eating
/// somebody's recording is a test rather than a comment.
@Suite("Stop tail")
struct StopTailPolicyTests {
    struct Case {
        let name: String
        let travel: TimeInterval?
        let duration: TimeInterval
        let expected: TimeInterval
    }

    @Test("The trim is the trip to the button, and nothing else", arguments: [
        Case(name: "a hotkey stop trims nothing", travel: nil, duration: 60, expected: 0),
        Case(name: "a click where the pointer already was trims nothing", travel: 0.05, duration: 60, expected: 0),
        Case(name: "the usual trip comes off", travel: 1.1, duration: 60, expected: 1.1),
        Case(name: "resting on the controls is not travel", travel: 45, duration: 120, expected: 2.5),
        Case(name: "at the floor, nothing", travel: 0.19, duration: 60, expected: 0),
        Case(name: "just past the floor, all of it", travel: 0.21, duration: 60, expected: 0.21)
    ])
    func tail(_ testCase: Case) {
        let tail = StopTailPolicy.tail(travel: testCase.travel, duration: testCase.duration)
        #expect(abs(tail - testCase.expected) < 0.0001, "\(testCase.name)")
    }

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
}
