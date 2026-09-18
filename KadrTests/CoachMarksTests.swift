import AppKit
import SettingsKit
import SwiftUI
import Testing
@testable import Kadr

/// First-run tips: shown once, dismissable, and armed again on request (docs/03 §8.2).
@MainActor
@Suite("First-run tips")
struct CoachMarksTests {
    private func settings() -> AppSettings {
        AppSettings(store: throwawayDefaults())
    }

    private func window() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        window.contentView = view
        window.orderFrontRegardless()
        return (window, view)
    }

    private func wait(until condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A new user has every tip ahead of them")
    func freshFlags() {
        let settings = settings()
        #expect(!settings.hasSeenMenuBarHint)
        #expect(!settings.hasSeenIslandTour)
        #expect(CoachMarks(settings: settings).isTourNeeded)
    }

    @Test("The tour counts as seen once it closes, however it closes")
    func tourClosesAsSeen() async {
        let settings = settings()
        let coach = CoachMarks(settings: settings)
        let (window, view) = window()
        defer { window.orderOut(nil) }

        coach.startIslandTour(pointingAt: NSRect(x: 20, y: 20, width: 500, height: 52), in: view)
        #expect(!settings.hasSeenIslandTour, "shown is not the same as seen")
        coach.islandDidClose()
        await wait { settings.hasSeenIslandTour }
        #expect(settings.hasSeenIslandTour)
        #expect(!coach.isTourNeeded)

        // And it does not come back on the next opening.
        coach.startIslandTour(pointingAt: .zero, in: view)
        coach.islandDidClose()
        #expect(settings.hasSeenIslandTour)
    }

    @Test("Dismissing a hint that never appeared does not use it up")
    func unshownHintIsNotSeen() {
        let settings = settings()
        let coach = CoachMarks(settings: settings)
        coach.scheduleMenuBarHint { nil }
        coach.dismissMenuBarHint()
        #expect(!settings.hasSeenMenuBarHint)
    }

    @Test("Show Tips Again arms all three")
    func resetAll() {
        let settings = settings()
        settings.hasSeenMenuBarHint = true
        settings.hasSeenIslandTour = true
        settings.hasSeenQuickAccessTip = true
        CoachMarks(settings: settings).resetAll()
        #expect(!settings.hasSeenMenuBarHint)
        #expect(!settings.hasSeenIslandTour)
        #expect(!settings.hasSeenQuickAccessTip)
    }

    @Test("The tour teaches the keys the island actually answers to")
    func tourMatchesTheIsland() {
        let steps = IslandTourStep.all
        #expect(steps.count == 3)
        for row in steps[0].rows + steps[1].rows {
            let key = row.key.lowercased()
            let isMode = AllInOneMode.matching(shortcut: key) != nil
            let isTool = AllInOneTool.matching(shortcut: key) != nil
            #expect(isMode || isTool, "\(row.key) does nothing in the island")
        }
        #expect(steps[2].offersShortcutSettings)
        #expect(steps[2].rows.allSatisfy { !$0.key.isEmpty })
    }

    @Test("The island's glass is found inside its hosting view", arguments: [true, false])
    func barInHostingView(flipped: Bool) {
        let slack = RecordingBarMetrics.shadowSlack
        let reserve = RecordingBarMetrics.tooltipReserve
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 52 + slack * 2 + reserve)
        let bar = AllInOneHUD.barFrame(inHostingBounds: bounds, flipped: flipped)
        #expect(bar.height == 52)
        #expect(bar.width == 600 - slack * 2)
        #expect(bar.minY == (flipped ? slack + reserve : slack))
    }
}

@MainActor
@Suite("Island tour pages")
struct IslandTourPagingTests {
    @Test("Pages move one at a time and stop at either end")
    func paging() {
        let model = IslandTourModel(steps: IslandTourStep.all)
        #expect(model.index == 0)
        #expect(!model.move(by: -1))
        #expect(model.move(by: 1))
        #expect(model.move(by: 1))
        #expect(model.isLast)
        #expect(!model.move(by: 1))
        #expect(model.index == 2)
        #expect(model.move(by: -1))
        #expect(model.index == 1)
    }

    @Test("Next walks the tour in place, and Done after the last page ends it as seen")
    func nextToDone() async {
        let settings = AppSettings(store: throwawayDefaults())
        let coach = CoachMarks(settings: settings)
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        coach.startIslandTour(pointingAt: NSRect(x: 20, y: 20, width: 500, height: 52), in: view)
        #expect(coach.tourPage == 0)
        coach.advanceTour()
        #expect(coach.tourPage == 1)
        coach.advanceTour()
        #expect(coach.tourPage == 2)
        coach.advanceTour()
        for _ in 0 ..< 200 where !settings.hasSeenIslandTour {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(settings.hasSeenIslandTour)
        #expect(coach.tourPage == nil)
    }
}
