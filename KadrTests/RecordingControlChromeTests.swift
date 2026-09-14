import CoreGraphics
import SettingsKit
import SwiftUI
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
        #expect(compact.leftWingWidth < 120)
        #expect(compact.islandWidth == compact.leftWingWidth + 180 + compact.rightWingWidth)
        #expect(compact.islandWidth < 380)

        let expanded = RecordingNotchLayout(
            hardware: hardware,
            isExpanded: true,
            hasPreRoll: false
        )
        #expect(expanded.windowSize == compact.windowSize)
        #expect(compact.windowSize.width >= expanded.islandWidth)
        #expect(expanded.windowSize.height == compact.windowSize.height)
        #expect(expanded.islandWidth > compact.islandWidth)
        #expect(expanded.islandWidth - compact.islandWidth == RecordingNotchLayout.hoverExpansion)
        #expect(RecordingNotchLayout.hoverExpansion <= 14)
        #expect(RecordingNotchLayout.endInset >= 18)
        #expect(RecordingNotchLayout.cameraSidePad == 0)
        assertCameraCentered(compact)
        assertCameraCentered(expanded)
        assertCameraCentered(
            RecordingNotchLayout(hardware: hardware, isExpanded: false, hasPreRoll: true)
        )
    }

    @Test("Countdown wings stay clear of the camera housing")
    func countdownClearsTheCamera() {
        let hardware = RecordingNotchMetrics(width: 180, height: 32)
        let countdown = RecordingNotchLayout(
            hardware: hardware,
            isExpanded: false,
            hasPreRoll: true
        )
        #expect(countdown.leftWingWidth > countdown.rightWingWidth)
        #expect(countdown.islandLeadingInset >= RecordingNotchLayout.windowEarPad)
        assertCameraCentered(countdown)
        #expect(countdown.islandLeadingInset > 0)
    }

    @Test("The pill ears sit inside the window, not on its square clip")
    func pillEarsAreInsetFromTheWindow() {
        let hardware = RecordingNotchMetrics(width: 180, height: 32)
        let countdown = RecordingNotchLayout(
            hardware: hardware,
            isExpanded: false,
            hasPreRoll: true
        )
        let expanded = RecordingNotchLayout(
            hardware: hardware,
            isExpanded: true,
            hasPreRoll: false
        )
        #expect(countdown.islandLeadingInset >= RecordingNotchLayout.windowEarPad)
        #expect(expanded.islandLeadingInset >= RecordingNotchLayout.windowEarPad)
        let trailing = countdown.windowSize.width - countdown.islandLeadingInset - countdown.islandWidth
        #expect(trailing >= RecordingNotchLayout.windowEarPad)
    }

    @Test("The shell uses pill ears, not a rectangle")
    func shellCornerRadii() {
        let shape = RecordingNotchShape.forShell(height: 32)
        #expect(shape.bottomCornerRadius >= 14)
        #expect(shape.topCornerRadius == 0)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 240, height: 32))
        // Flush top: no concave nicks in the menu bar (countdown used to show these).
        #expect(path.contains(CGPoint(x: 2, y: 2)))
        #expect(path.contains(CGPoint(x: 238, y: 2)))
        #expect(path.contains(CGPoint(x: 2, y: 16)))
        #expect(path.contains(CGPoint(x: 238, y: 16)))
    }

    private func assertCameraCentered(_ layout: RecordingNotchLayout) {
        let cameraMid =
            layout.islandLeadingInset
            + layout.leftWingWidth
            + layout.cameraReserveWidth / 2
        #expect(abs(cameraMid - layout.windowSize.width / 2) < 0.5)
    }
}
