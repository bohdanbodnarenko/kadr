import CoreGraphics
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

    @Test("The shell is menu-bar height with wings beside the camera reserve")
    func shellGeometry() {
        let hardware = RecordingNotchMetrics(width: 180, height: 32)
        let compact = RecordingNotchLayout(
            hardware: hardware,
            isExpanded: false,
            hasPreRoll: false
        )
        #expect(compact.stripHeight == 32)
        #expect(compact.shellHeight == 32)
        #expect(compact.cameraReserveWidth == 180)
        #expect(compact.windowSize == CGSize(width: 420, height: 32))
        #expect(compact.islandWidth == 314)

        let expanded = RecordingNotchLayout(
            hardware: hardware,
            isExpanded: true,
            hasPreRoll: false
        )
        #expect(expanded.windowSize.height == compact.windowSize.height)
        #expect(expanded.islandWidth > compact.islandWidth)
        #expect(expanded.islandWidth == 424)
    }
}
