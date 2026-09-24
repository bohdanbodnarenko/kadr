import CoreGraphics
import Testing
@testable import Kadr

@Suite("Recording bar tooltip placement")
struct RecordingBarTooltipClampTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var controlMidX: CGFloat
        var pillWidth: CGFloat
        var expected: CGFloat
        var testDescription: String {
            "control at \(controlMidX), pill \(pillWidth) wide"
        }
    }

    /// A 400 pt bar whose panel reaches 24 pt past each end.
    @Test("The pill stays inside the panel", arguments: [
        Case(controlMidX: 20, pillWidth: 160, expected: 56), // left end: pushed right
        Case(controlMidX: 200, pillWidth: 160, expected: 200), // middle: on the control
        Case(controlMidX: 390, pillWidth: 160, expected: 344), // right end: pushed left
        Case(controlMidX: 20, pillWidth: 500, expected: 200) // wider than the panel
    ])
    func clamps(_ testCase: Case) {
        let x = RecordingBarTooltipLayer.clampedCentreX(
            controlMidX: testCase.controlMidX, pillWidth: testCase.pillWidth, barWidth: 400, overhang: 24
        )
        #expect(x == testCase.expected)
    }
}
