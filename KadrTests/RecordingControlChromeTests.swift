import SettingsKit
import Testing
@testable import Kadr

@MainActor
@Suite("Recording control chrome")
struct RecordingControlChromePlacementTests {
    @Test("Notch docking needs the setting, a notched display, and a live take")
    func dockingRules() {
        #expect(
            RecordingControlBar.shouldDockToNotch(
                chrome: .notch,
                screenHasNotch: true,
                isLiveSession: true
            )
        )
        #expect(
            !RecordingControlBar.shouldDockToNotch(
                chrome: .island,
                screenHasNotch: true,
                isLiveSession: true
            )
        )
        #expect(
            !RecordingControlBar.shouldDockToNotch(
                chrome: .notch,
                screenHasNotch: false,
                isLiveSession: true
            )
        )
        #expect(
            !RecordingControlBar.shouldDockToNotch(
                chrome: .notch,
                screenHasNotch: true,
                isLiveSession: false
            )
        )
    }
}
