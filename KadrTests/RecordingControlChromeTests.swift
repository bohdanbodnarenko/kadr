import CoreGraphics
import SettingsKit
import SwiftUI
import Testing
@testable import Kadr

@MainActor
@Suite("Recording control chrome")
struct RecordingControlChromePlacementTests {
    private let hardware = RecordingNotchMetrics(width: 180, height: 32)

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

    @Test("Compact is menu-bar height, with status ears either side of the camera")
    func compactGeometry() {
        let compact = RecordingNotchLayout(hardware: hardware, isExpanded: false)
        #expect(!compact.showsRow)
        #expect(compact.shellHeight == 32)
        #expect(compact.stripWidth == 180 + 2 * RecordingNotchLayout.earWidth)
        #expect(compact.minimumShellWidth == compact.stripWidth)
        // Room for "1:02:03" in the ear without reaching the camera housing.
        #expect(RecordingNotchLayout.earWidth - compact.earPadding >= 50)
    }

    @Test("Expanded puts the controls in a row below the camera, never beside it")
    func expandedGeometry() {
        let compact = RecordingNotchLayout(hardware: hardware, isExpanded: false)
        let expanded = RecordingNotchLayout(hardware: hardware, isExpanded: true)
        #expect(expanded.showsRow)
        #expect(
            expanded.shellHeight == 32
                + RecordingNotchLayout.rowTopGap
                + RecordingNotchLayout.rowHeight
                + RecordingNotchLayout.rowBottomPadding
        )
        #expect(RecordingNotchLayout.rowHeight >= RecordingBarMetrics.controlSize)
        #expect(expanded.minimumShellWidth >= compact.minimumShellWidth)
        #expect(expanded.shape.bottomCornerRadius > compact.shape.bottomCornerRadius)
    }

    @Test("Hidden collapses to the hardware notch, so showing grows out of it")
    func hiddenGeometry() {
        let hidden = RecordingNotchLayout(hardware: hardware, isExpanded: true, isVisible: false)
        #expect(!hidden.showsRow)
        #expect(hidden.minimumShellWidth == 180)
        #expect(hidden.shellHeight == 32)
    }

    @Test("One window holds every state plus the tooltip below it")
    func windowHoldsEveryState() {
        let states = [
            RecordingNotchLayout(hardware: hardware, isExpanded: false),
            RecordingNotchLayout(hardware: hardware, isExpanded: true),
            RecordingNotchLayout(hardware: hardware, isExpanded: true, isVisible: false)
        ]
        let window = states[0].windowSize
        for state in states {
            #expect(state.windowSize == window)
        }
        #expect(window.width >= RecordingNotchLayout.maximumExpandedWidth)
        #expect(window.height >= states[1].expandedHeight + RecordingNotchLayout.tooltipReserve)
    }

    @Test("Top ears are concave, bottom corners convex")
    func shellShape() {
        let shape = RecordingNotchShape(topCornerRadius: 10, bottomCornerRadius: 16)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 240, height: 80))
        // Full width along the display edge.
        #expect(path.contains(CGPoint(x: 120, y: 0.5)))
        // The ear curves inward below the edge…
        #expect(!path.contains(CGPoint(x: 2, y: 8)))
        #expect(!path.contains(CGPoint(x: 238, y: 8)))
        // …to the body.
        #expect(path.contains(CGPoint(x: 12, y: 40)))
        // Rounded bottom corners.
        #expect(!path.contains(CGPoint(x: 11, y: 79)))
        #expect(path.contains(CGPoint(x: 120, y: 79)))
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

    @Test("A zero fitting size is never used as the panel size")
    func firstShowRejectsZero() {
        let size = RecordingBarMetrics.resolvedIslandSize(fitting: .zero)
        #expect(size.width >= 200)
        #expect(size.height >= 48)
        let laidOut = RecordingBarMetrics.resolvedIslandSize(fitting: CGSize(width: 400, height: 72))
        #expect(laidOut == CGSize(width: 400, height: 72))
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

    @Test("The default bar sits 48 pt above the visible frame, centerd")
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

    /// docs/18 REC-9: the notch docks only when its display is the one the take is about.
    @Test("The notch docks only for its own display, or the pointer's for a window", arguments: [
        (CGDirectDisplayID?.some(1), CGDirectDisplayID?.some(1), CGDirectDisplayID?.some(2), true),
        (1, 2, 1, false),
        (1, nil, 1, true),
        (1, nil, 2, false),
        (nil, 1, 1, false)
    ])
    func notchRelevance(
        notch: CGDirectDisplayID?,
        recorded: CGDirectDisplayID?,
        pointer: CGDirectDisplayID?,
        docks: Bool
    ) {
        #expect(RecordingControlBar.notchIsRelevant(
            notchDisplay: notch,
            recordedDisplay: recorded,
            pointerDisplay: pointer
        ) == docks)
    }
}
