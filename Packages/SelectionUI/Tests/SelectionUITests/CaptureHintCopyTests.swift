import Testing
@testable import SelectionUI

@Suite("Capture overlay hints")
struct CaptureHintCopyTests {
    @Test("Idle area capture names the keys")
    func idleCapture() {
        let text = CaptureHintCopy.text(
            purpose: .capture,
            mode: .area,
            phase: .idle,
            isEyedropper: false
        )
        #expect(text?.contains("Drag") == true)
        #expect(text?.contains("F for this display") == true)
    }

    @Test("A live drag tells the user about Space")
    func dragging() {
        let text = CaptureHintCopy.text(
            purpose: .capture,
            mode: .area,
            phase: .dragging,
            isEyedropper: false
        )
        #expect(text?.contains("Space") == true)
    }

    @Test("A finished rectangle hides the hint")
    func selectedHidesHint() {
        #expect(CaptureHintCopy.text(
            purpose: .capture,
            mode: .area,
            phase: .selected,
            isEyedropper: false
        ) == nil)
    }

    @Test("Window mode names Tab")
    func windowMode() {
        let text = CaptureHintCopy.text(
            purpose: .capture,
            mode: .window,
            phase: .idle,
            isEyedropper: false
        )
        #expect(text?.contains("Tab") == true)
    }
}
