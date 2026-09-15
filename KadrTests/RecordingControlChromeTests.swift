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

@MainActor
@Suite("Recording island chrome")
struct RecordingIslandChromeTests {
    @Test("Island controls stay comfortably hittable")
    func hitTargets() {
        #expect(RecordingBarMetrics.controlSize >= 20)
        #expect(RecordingBarMetrics.iconSize >= 12)
        #expect(RecordingBarMetrics.barHeight >= 40)
    }

    @Test("The tooltip band sits above the capsule, not inside it")
    func tooltipReservesSpace() {
        #expect(RecordingBarMetrics.tooltipReserve > RecordingBarMetrics.tooltipPillHeight)
    }

    @Test("The fixed panel holds the bar, its tooltip and its shadow")
    func panelHoldsTheBar() {
        let size = RecordingControlBar.panelSize
        #expect(
            size.height == RecordingBarMetrics.tooltipReserve
                + RecordingBarMetrics.barHeight
                + RecordingBarMetrics.shadowSlack
        )
        // The picker is the widest mode: 12 controls, two dividers.
        let picker = 12 * RecordingBarMetrics.controlSize + 2 * 11 + 13 * RecordingBarMetrics.controlSpacing
            + 2 * RecordingBarMetrics.horizontalPadding
        #expect(size.width >= picker + 2 * 60)
    }

    @Test("Mode follows the picker, then the countdown, then the clock", arguments: [
        (true, false, false, RecordingControlBarModel.Mode.picker),
        (true, true, true, .preRoll),
        (false, true, true, .preRoll),
        (false, true, false, .live),
        (true, true, false, .live)
    ])
    func modeRules(hasPicker: Bool, hasSession: Bool, hasPreRoll: Bool, expected: RecordingControlBarModel.Mode) {
        #expect(
            RecordingControlBarModel.mode(
                hasPicker: hasPicker,
                hasSession: hasSession,
                hasPreRoll: hasPreRoll
            ) == expected
        )
    }

    @Test("The default bar sits 48 pt above the visible frame, centred")
    func defaultPlacement() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 820)
        let origin = RecordingControlBar.defaultOrigin(in: visible)
        #expect(origin.x + RecordingControlBar.panelSize.width / 2 == visible.midX)
        #expect(origin.y + RecordingBarMetrics.shadowSlack == visible.minY + 48)
        #expect(RecordingControlBar.clampedOrigin(origin, barWidth: 540, in: visible) == origin)
    }

    @Test("A remembered position is clamped so the bar, not the panel, stays visible")
    func clampKeepsTheBarOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = RecordingControlBar.panelSize
        let barWidth: CGFloat = 400

        let offLeft = RecordingControlBar.clampedOrigin(CGPoint(x: -2000, y: -500), barWidth: barWidth, in: visible)
        let leftBarEdge = offLeft.x + (size.width - barWidth) / 2
        #expect(leftBarEdge >= visible.minX)
        #expect(offLeft.y + RecordingBarMetrics.shadowSlack >= visible.minY)

        let offTop = RecordingControlBar.clampedOrigin(CGPoint(x: 5000, y: 5000), barWidth: barWidth, in: visible)
        let rightBarEdge = offTop.x + (size.width + barWidth) / 2
        #expect(rightBarEdge <= visible.maxX)
        #expect(offTop.y + RecordingBarMetrics.shadowSlack + RecordingBarMetrics.barHeight <= visible.maxY)
    }

    @Test("A zero fitting size is never used as the panel size")
    func firstShowRejectsZero() {
        let size = RecordingBarMetrics.resolvedIslandSize(fitting: .zero)
        #expect(size.width >= 200)
        #expect(size.height >= 48)
        let laidOut = RecordingBarMetrics.resolvedIslandSize(fitting: CGSize(width: 400, height: 72))
        #expect(laidOut == CGSize(width: 400, height: 72))
    }
}
