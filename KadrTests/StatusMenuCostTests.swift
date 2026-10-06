import AppKit
import Foundation
import Testing
@testable import Kadr

/// Opening the status menu touches no disk and decodes nothing on the main thread
/// (docs/10 R2.4, PRD §8).
@MainActor
@Suite("Status menu cost", .serialized)
struct StatusMenuCostTests {
    /// Counts on whatever thread it is called from, and remembers whether that was main.
    private final class CountingSource: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var onMain = false
        let value: Int

        init(value: Int) {
            self.value = value
        }

        func count() -> Int {
            lock.withLock {
                calls += 1
                if Thread.isMainThread {
                    onMain = true
                }
            }
            return value
        }

        var callCount: Int {
            lock.withLock { calls }
        }

        var ranOnMain: Bool {
            lock.withLock { onMain }
        }
    }

    @Test("The recovery count is taken off the main thread and cached")
    func countsOffMain() async {
        let source = CountingSource(value: 2)
        let counter = UnfinishedRecordingsCounter(counter: { source.count() })
        #expect(counter.latest < 1, "nothing is counted until asked")

        let reported = await withCheckedContinuation { continuation in
            counter.refresh { continuation.resume(returning: $0) }
        }
        #expect(reported == 2)
        #expect(counter.latest == 2)
        #expect(!source.ranOnMain)
    }

    @Test("Asking again while a recount runs joins it rather than starting another")
    func concurrentRefreshesShareOneCount() async {
        let source = CountingSource(value: 1)
        let counter = UnfinishedRecordingsCounter(counter: {
            Thread.sleep(forTimeInterval: 0.05)
            return source.count()
        })
        let results = await withCheckedContinuation { (done: CheckedContinuation<[Int], Never>) in
            var collected: [Int] = []
            for _ in 0 ..< 2 {
                counter.refresh { value in
                    collected.append(value)
                    if collected.count == 2 {
                        done.resume(returning: collected)
                    }
                }
            }
        }
        #expect(results == [1, 1])
        #expect(source.callCount <= 2)
        #expect(counter.latest == 1)
    }

    @Test("The recovery row reads the count it is given", arguments: [
        (1, "Recover Unfinished Recording…"),
        (2, "Recover 2 Unfinished Recordings…"),
        (12, "Recover 12 Unfinished Recordings…")
    ])
    func recoveryTitle(count: Int, title: String) {
        #expect(StatusItemController.recoveryTitle(count: count) == title)
    }

    @Test("A count that arrives after the menu opened updates the row in place")
    func lateCountUpdatesRow() {
        var reply: ((Int) -> Void)?
        let controller = StatusItemController(
            perform: { _ in },
            openSettings: {},
            unfinishedRecordings: { 0 },
            refreshUnfinishedRecordings: { reply = $0 }
        )
        let menu = NSMenu()
        controller.addRecoveryItem(to: menu)
        let item = menu.items.last
        #expect(item?.isHidden == true, "nothing to recover yet")

        reply?(3)
        #expect(item?.isHidden == false)
        #expect(item?.title == "Recover 3 Unfinished Recordings…")

        reply?(0)
        #expect(item?.isHidden == true)
        NSStatusBar.system.removeStatusItem(controller.statusItem)
    }

    @Test("Only the glyph decides whether two appearances share an image", arguments: [
        ("record.circle", "record.circle", false, false, true),
        ("record.circle", "pause.circle.fill", false, false, false),
        ("viewfinder", "viewfinder", true, false, false),
        ("viewfinder", "camera.viewfinder", true, true, false)
    ])
    func appearanceKey(symbol: String, otherSymbol: String, template: Bool, otherTemplate: Bool, same: Bool) {
        let first = StatusItemAppearance(
            symbol: symbol,
            accessibilityDescription: "Kadr",
            isTemplate: template,
            title: " 0:01",
            length: NSStatusItem.variableLength,
            toolTip: "one"
        )
        let second = StatusItemAppearance(
            symbol: otherSymbol,
            accessibilityDescription: "Kadr",
            isTemplate: otherTemplate,
            title: " 0:02",
            length: NSStatusItem.squareLength,
            toolTip: "two"
        )
        #expect((first.imageKey == second.imageKey) == same)
    }

    /// docs/18 SH-3: the update badge is a different image, not a cached plain one.
    @Test("A badged appearance has its own image key")
    func badgeChangesKey() {
        var plain = StatusItemAppearance(
            symbol: "camera.viewfinder",
            accessibilityDescription: "Kadr",
            isTemplate: true,
            title: "",
            length: NSStatusItem.squareLength,
            toolTip: "one"
        )
        let key = plain.imageKey
        plain.isBadged = true
        #expect(plain.imageKey != key)
    }

    @Test("A running clock rebuilds no image and touches only the title")
    func clockTickKeepsTheImage() {
        let controller = StatusItemController(perform: { _ in }, openSettings: {})
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        controller.showRecordingIcon(elapsed: "0:01", isPaused: false)
        let image = controller.statusItem.button?.image
        #expect(image != nil)

        controller.showRecordingIcon(elapsed: "0:02", isPaused: false)
        #expect(controller.statusItem.button?.image === image, "the same image object is kept")
        #expect(controller.statusItem.button?.title == " 0:02")

        controller.showRecordingIcon(elapsed: "0:02", isPaused: true)
        #expect(controller.statusItem.button?.image !== image, "pausing swaps the glyph")

        controller.showRecordingIcon(elapsed: "0:02", isPaused: false)
        #expect(controller.statusItem.button?.image === image, "and the cached one comes back")
        controller.showIdleIcon()
        #expect(controller.statusItem.button?.title.isEmpty == true)
    }

    @Test("Menu-bar visibility is observed once, and can be stopped")
    func visibilityObservedOnce() {
        let controller = StatusItemController(perform: { _ in }, openSettings: {})
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let token = controller.menuBarVisibilityToken
        #expect(token != nil)
        controller.observeMenuBarVisibility()
        #expect(controller.menuBarVisibilityToken === token, "a second call must not add a second observer")
        controller.stopObservingMenuBarVisibility()
        #expect(controller.menuBarVisibilityToken == nil)
        #expect(controller.visibilityObservation == nil)
    }
}
