import AppKit
import Testing
@testable import Kadr

/// The rows the status menu grows for testers and for a waiting update
/// (docs/17 T-DIAG-1, T-REL-4, T-SH-6).
@MainActor
@Suite("Status menu tester rows")
struct StatusMenuTesterRowsTests {
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
    }

    @Test("Diagnostics rows appear only with ⌥ held", arguments: [true, false])
    func optionRows(optionHeld: Bool) {
        var exported = 0
        let controller = StatusItemController(
            perform: { _ in },
            openSettings: {},
            exportDiagnostics: { exported += 1 }
        )
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        controller.menuNeedsUpdate(controller.menu, optionHeld: optionHeld)
        let shown = titles(controller.menu)
        #expect(shown.contains("Export Diagnostics…") == optionHeld)
        #expect(shown.contains("Report a Problem…") == optionHeld)
        if optionHeld {
            let item = controller.menu.items.first { $0.title == "Export Diagnostics…" }
            if let item, let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            #expect(exported == 1)
        }
    }

    @Test("An update found in the background waits in the menu")
    func updateRow() {
        let controller = StatusItemController(
            perform: { _ in },
            openSettings: {},
            availableUpdate: { "0.9.1" }
        )
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        controller.menuNeedsUpdate(controller.menu, optionHeld: false)
        #expect(titles(controller.menu).contains("Update to 0.9.1…"))
    }

    @Test("Discard sits in its own group, and both destructive rows ask first")
    func recordingRows() throws {
        let controls = RecordingControls(elapsedText: "0:12", isPaused: false, stop: {}, togglePause: {}, cancel: {})
        let controller = StatusItemController(perform: { _ in }, openSettings: {}, recordingControls: { controls })
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        controller.menuNeedsUpdate(controller.menu, optionHeld: false)
        let items = controller.menu.items
        let discard = try #require(items.firstIndex { $0.title == "Discard Recording…" })
        #expect(items[discard - 1].isSeparatorItem)
        #expect(items.contains { $0.title == "Restart Recording…" })
    }

    @Test("Hide and Show toggles say it once, in the title")
    func toggleRowsHaveNoCheckmark() {
        let controller = StatusItemController(
            perform: { _ in },
            openSettings: {},
            overlayCardCount: { 1 },
            overlaysAreHidden: { true },
            pinCount: { 1 },
            pinsAreHidden: { true }
        )
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let items = controller.overlaySubmenuItems().filter { !$0.isSeparatorItem }
        #expect(items.contains { $0.title == "Show Cards" })
        #expect(items.contains { $0.title == "Show Pins" })
        #expect(items.allSatisfy { $0.state == .off })
    }
}
