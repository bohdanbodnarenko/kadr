import Foundation
import Testing
@testable import EditorUI

/// The elapsed time beside a transcription's progress (docs/18 STU-9).
@Suite("Transcription elapsed")
struct TranscriptionElapsedTests {
    @Test("Elapsed time reads as minutes and seconds", arguments: [
        (0.0, "0:00"),
        (59.9, "0:59"),
        (125.0, "2:05"),
        (-3.0, "0:00")
    ])
    func label(seconds: TimeInterval, expected: String) {
        #expect(TranscriptionElapsed.label(seconds) == expected)
    }
}
