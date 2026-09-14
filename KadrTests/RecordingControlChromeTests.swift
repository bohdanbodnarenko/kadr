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
        #expect(compact.windowSize == CGSize(width: compact.islandWidth, height: 32))
        #expect(compact.leftWingWidth < 120)
        #expect(compact.islandWidth == compact.leftWingWidth + 180 + compact.rightWingWidth)
        #expect(compact.islandWidth < 380)

        let expanded = RecordingNotchLayout(
            hardware: hardware,
            isExpanded: true,
            hasPreRoll: false
        )
        #expect(expanded.windowSize.height == compact.windowSize.height)
        #expect(expanded.islandWidth > compact.islandWidth)
        #expect(expanded.islandWidth - compact.islandWidth < 50)
        #expect(RecordingNotchLayout.endInset >= 12)
    }

    @Test("The shell uses pill ears, not a rectangle")
    func shellCornerRadii() {
        let shape = RecordingNotchShape.forShell(height: 32)
        #expect(shape.bottomCornerRadius >= 14)
        #expect(shape.topCornerRadius >= 8)
    }
}
