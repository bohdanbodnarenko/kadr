import Foundation
import Testing
@testable import VisionServices

/// docs/18 STU-9: transcription progress moves with the audio read, not in two jumps.
@Suite("Speech progress")
struct SpeechProgressTests {
    @Test("Progress follows the seconds read, split between tracks", arguments: [
        (0, 1, 0.0, 600.0, 0.18),
        (0, 1, 300.0, 600.0, 0.555),
        (0, 1, 600.0, 600.0, 0.93),
        (0, 2, 300.0, 300.0, 0.555),
        (1, 2, 150.0, 300.0, 0.7425),
        (0, 1, 900.0, 600.0, 0.93)
    ])
    func fraction(track: Int, count: Int, done: TimeInterval, duration: TimeInterval, expected: Double) {
        let value = SpeechXPCHandler.fraction(track: track, of: count, secondsDone: done, duration: duration)
        #expect(abs(value - expected) < 0.0001)
    }

    @Test("A track of unknown length reports where it started")
    func unknownDuration() {
        #expect(SpeechXPCHandler.fraction(track: 0, of: 1, secondsDone: 42, duration: nil) == 0.18)
    }
}
