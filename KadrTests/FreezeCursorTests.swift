import SelectionUI
import Testing
@testable import Kadr

/// "Include the pointer" reaches an area capture through its freeze (docs/17 T-CAP-12).
@Suite("Pointer in the freeze")
struct FreezeCursorTests {
    @Test("Only a capture that keeps the picture shows the pointer", arguments: [
        (true, SelectionPurpose.capture, false, true),
        (true, .inspect, false, true),
        (true, .recognizeText, false, false),
        (true, .scrollingCapture, false, false),
        (true, .capture, true, false),
        (false, .capture, false, false)
    ])
    func rule(setting: Bool, purpose: SelectionPurpose, eyedropper: Bool, expected: Bool) {
        #expect(AreaCaptureCoordinator.freezeIncludesCursor(
            setting: setting,
            purpose: purpose,
            eyedropper: eyedropper
        ) == expected)
    }
}
