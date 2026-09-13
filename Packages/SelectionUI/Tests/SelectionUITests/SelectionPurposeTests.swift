import Shared
import Testing
@testable import SelectionUI

@Suite("Selection purpose")
struct SelectionPurposeTests {
    @Test("Freeze inspect is labelled so it is not mistaken for a capture")
    func inspectBadge() {
        #expect(SelectionPurpose.inspect.badge == "FREEZE")
        #expect(SelectionPurpose.capture.badge == nil)
        #expect(SelectionPurpose.recognizeText.badge == "TEXT")
        #expect(SelectionPurpose.scrollingCapture.badge == "SCROLL")
    }

    @MainActor
    @Test("Stealing freezes without an overlay yields nothing")
    func stealWithoutPresent() {
        let overlay = SelectionOverlayController()
        #expect(overlay.heldFreezes.isEmpty)
        #expect(overlay.stealFreezesAndDismiss().isEmpty)
        #expect(!overlay.isPresented)
        #expect(overlay.currentPurpose == .capture)
    }
}
