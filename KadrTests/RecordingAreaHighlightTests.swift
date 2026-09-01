import AppKit
import CoreGraphics
import Foundation
import OverlayKit
import RecordingCore
import Shared
import Testing
@testable import Kadr

@Suite("Recording area highlight")
struct RecordingAreaHighlightGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let hole = CGRect(x: 200, y: 150, width: 400, height: 300)

    @Test("The dim covers the desk around the recorded region")
    func dimCoversTheOutside() {
        let path = RecordingAreaHighlight.dimPath(bounds: bounds, hole: hole)
        #expect(path.contains(CGPoint(x: 10, y: 10), using: .evenOdd, transform: .identity))
        #expect(path.contains(CGPoint(x: 990, y: 790), using: .evenOdd, transform: .identity))
    }

    @Test("The recorded region is a hole, not dimmed")
    func holeIsClear() {
        let path = RecordingAreaHighlight.dimPath(bounds: bounds, hole: hole)
        #expect(!path.contains(CGPoint(x: 400, y: 300), using: .evenOdd, transform: .identity))
    }
}

@MainActor
@Suite("Recording area highlight panel")
struct RecordingAreaHighlightPanelTests {
    @Test("The highlight excludes itself from captures")
    func panelIsExcluded() {
        let highlight = RecordingAreaHighlight()
        let before = CaptureExclusionRegistry.shared.excludedWindowIDs
        highlight.show(
            region: DisplayRect(x: 120, y: 80, width: 320, height: 240),
            displayID: CGMainDisplayID()
        )
        defer { highlight.hide() }
        #expect(highlight.isShowing)
        let added = CaptureExclusionRegistry.shared.excludedWindowIDs.subtracting(before)
        #expect(added.count == 1, "the highlight was not registered for capture exclusion")
    }

    @Test("A whole-display recording does not dim the screen")
    func displayTargetHides() {
        let highlight = RecordingAreaHighlight()
        highlight.show(
            region: DisplayRect(x: 0, y: 0, width: 100, height: 100),
            displayID: CGMainDisplayID()
        )
        highlight.show(for: .display(CGMainDisplayID()))
        #expect(!highlight.isShowing)
    }

    @Test("A window recording dims around the window")
    func windowTargetShowsAHole() {
        let highlight = RecordingAreaHighlight()
        highlight.showWindow(
            hole: DisplayRect(x: 80, y: 60, width: 400, height: 300),
            displayID: CGMainDisplayID()
        )
        defer { highlight.hide() }
        #expect(highlight.isShowing)
    }

    @Test("A hole on the main display is attributed to that display")
    func displayIDContainingMain() {
        let bounds = DisplayRect(cgRect: CGDisplayBounds(CGMainDisplayID()))
        let hole = DisplayRect(
            x: bounds.minX + 8,
            y: bounds.minY + 8,
            width: 40,
            height: 40
        )
        #expect(RecordingCoordinator.displayID(containing: hole) == CGMainDisplayID())
    }
}
