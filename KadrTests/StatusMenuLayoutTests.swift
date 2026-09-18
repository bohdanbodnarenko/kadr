import AppKit
import KeyboardShortcuts
import Testing
@testable import Kadr

/// The short menu, the island-first click, and the move to five default shortcuts
/// (docs/03 §1.4, §8.1).
@MainActor
@Suite("Status menu layout")
struct StatusMenuLayoutTests {
    private func makeController(
        needsSetup: Bool = false,
        overlays: Int = 0,
        pins: Int = 0,
        canRestore: Bool = false,
        recording: RecordingControls? = nil
    ) -> StatusItemController {
        StatusItemController(
            perform: { _ in },
            openSettings: {},
            needsSetup: { needsSetup },
            recordingControls: { recording },
            canRestore: { canRestore },
            overlayCardCount: { overlays },
            pinCount: { pins }
        )
    }

    private func visibleTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
    }

    @Test("An idle menu is History, Settings and Quit — no capture commands")
    func idleMenuIsShort() {
        let controller = makeController()
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        controller.menuNeedsUpdate(controller.menu)
        #expect(visibleTitles(controller.menu) == ["History…", "Settings…", "Quit Kadr"])
        let commands = controller.menu.items.compactMap { $0.representedObject as? String }
        #expect(commands.isEmpty, "capture commands belong to the island")
        #expect(controller.menu.items.first?.isSeparatorItem == false)
        #expect(!zip(controller.menu.items, controller.menu.items.dropFirst())
            .contains { $0.isSeparatorItem && $1.isSeparatorItem })
    }

    @Test("Setup appears only while a permission is missing", arguments: [true, false])
    func setupRowIsConditional(needsSetup: Bool) {
        let controller = makeController(needsSetup: needsSetup)
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        controller.menuNeedsUpdate(controller.menu)
        #expect(visibleTitles(controller.menu).contains("Finish Setup…") == needsSetup)
        #expect(!visibleTitles(controller.menu).contains("Check for Updates…"))
    }

    @Test("Pins & Overlays exists only when there is something in it", arguments: [
        (0, 0, false, [String]()),
        (2, 0, false, ["Save All Overlays", "Close All Overlays", "Hide Overlays"]),
        (0, 0, true, ["Restore Recently Closed"]),
        (0, 3, false, ["Hide Pins", "Close All Pins"]),
        (1, 1, true, [
            "Save All Overlays", "Close All Overlays", "Hide Overlays",
            "Restore Recently Closed", "Hide Pins", "Close All Pins"
        ])
    ])
    func overlaySubmenu(overlays: Int, pins: Int, canRestore: Bool, expected: [String]) {
        let controller = makeController(overlays: overlays, pins: pins, canRestore: canRestore)
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let titles = controller.overlaySubmenuItems().filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == expected)
        controller.menuNeedsUpdate(controller.menu)
        #expect(visibleTitles(controller.menu).contains("Pins & Overlays") == !expected.isEmpty)
    }

    @Test("A live recording leads the menu")
    func recordingComesFirst() {
        let controls = RecordingControls(elapsedText: "0:12", isPaused: false, stop: {}, togglePause: {}, cancel: {})
        let controller = makeController(recording: controls)
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        controller.menuNeedsUpdate(controller.menu)
        #expect(visibleTitles(controller.menu).first == "Recording — 0:12")
        #expect(visibleTitles(controller.menu).contains("Stop Recording"))
    }

    @Test("Right-click, Control-click and Option-click open the menu; a click opens the island", arguments: [
        StatusClickCase(isRight: false, modifiers: [], opensMenu: false),
        StatusClickCase(isRight: false, modifiers: [.control], opensMenu: true),
        StatusClickCase(isRight: false, modifiers: [.option], opensMenu: true),
        StatusClickCase(isRight: false, modifiers: [.shift], opensMenu: false),
        StatusClickCase(isRight: false, modifiers: [.command], opensMenu: false),
        StatusClickCase(isRight: true, modifiers: [], opensMenu: true)
    ])
    func clickRouting(_ click: StatusClickCase) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: click.isRight ? .rightMouseUp : .leftMouseUp,
            location: .zero,
            modifierFlags: click.modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
        #expect(StatusItemController.clickOpensMenu(event) == click.opensMenu)
    }

    @Test("A press with no mouse event opens the island, and the menu has an accessibility action")
    func accessibilityPressOpensIsland() {
        #expect(StatusItemController.clickOpensMenu(nil) == false)
        let controller = makeController()
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        #expect(controller.statusItem.button?.accessibilityCustomActions()?.map(\.name) == ["Show Kadr Menu"])
    }

    @Test("The island's tools cover every tool once")
    func islandToolsAreGrouped() {
        let grouped = AllInOneTool.groups.flatMap(\.self)
        #expect(grouped.count == AllInOneTool.allCases.count)
        #expect(Set(grouped) == Set(AllInOneTool.allCases))
        #expect(AllInOneTool.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    }

    @Test("Every island key is unique, and none is Return, Space or Escape")
    func islandKeysAreDistinct() {
        let keys = AllInOneMode.allCases.map(\.shortcut) + AllInOneTool.allCases.map(\.shortcut)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.isLetter && $0.isLowercase })
        for tool in AllInOneTool.allCases {
            #expect(AllInOneTool.matching(shortcut: String(tool.shortcut).uppercased()) == tool)
            #expect(AllInOneMode.matching(shortcut: String(tool.shortcut)) == nil)
        }
        #expect(AllInOneMode.area.keyCaption == "A")
    }
}

struct StatusClickCase: Sendable {
    let isRight: Bool
    let modifiers: NSEvent.ModifierFlags
    let opensMenu: Bool
}

@MainActor
@Suite("Shortcut defaults migration")
struct ShortcutDefaultsMigrationTests {
    typealias Shortcut = KeyboardShortcuts.Shortcut
    private typealias Migration = ShortcutDefaultsMigration

    private var newDefaults: [CaptureCommand: Shortcut] {
        var result: [CaptureCommand: Shortcut] = [:]
        for command in CaptureCommand.allCases {
            result[command] = command.shortcutName.initialShortcut
        }
        return result
    }

    private let island = Shortcut(.two, modifiers: [.command, .shift])

    private func plan(_ current: [CaptureCommand: Shortcut]) -> [(CaptureCommand, Shortcut?)] {
        Migration.plan(current: current, previous: Migration.previousDefaults, newDefaults: newDefaults)
    }

    private func apply(_ current: [CaptureCommand: Shortcut]) -> [CaptureCommand: Shortcut] {
        var result = current
        for (command, shortcut) in plan(current) {
            result[command] = shortcut
        }
        return result
    }

    @Test("An untouched install of either earlier version ends up with exactly the new defaults", arguments: [1, 2])
    func untouchedInstallMatchesFreshInstall(version: Int) {
        let saved = version == 1 ? Migration.versionOneDefaults : Migration.versionTwoDefaults
        let migrated = apply(saved)
        #expect(migrated == newDefaults)
        #expect(migrated.count == 5)
        #expect(migrated[.allInOne] == island)
    }

    @Test("A fresh install is left alone")
    func freshInstallUnchanged() {
        #expect(plan(newDefaults).isEmpty)
    }

    @Test("Shortcuts the user recorded are kept", arguments: [
        (CaptureCommand.captureWindow, Shortcut(.w, modifiers: [.command, .option])),
        (.captureArea, Shortcut(.x, modifiers: [.control, .command])),
        (.allInOne, Shortcut(.space, modifiers: [.control, .option])),
        (.openHistory, Shortcut(.h, modifiers: [.control, .option, .command]))
    ])
    func customShortcutSurvives(command: CaptureCommand, custom: Shortcut) {
        var current = Migration.versionOneDefaults
        current[command] = custom
        #expect(apply(current)[command] == custom)
    }

    @Test("When the new keys are taken, a command keeps the shortcut it had")
    func newDefaultYieldsToUserChoice() {
        var current = Migration.versionTwoDefaults
        current[.captureWindow] = island
        let migrated = apply(current)
        #expect(migrated[.captureWindow] == island)
        #expect(migrated[.allInOne] == Shortcut(.five, modifiers: [.control, .shift]))
    }

    @Test("Record Setup takes Control-Shift-6 from the old Record Display")
    func reusedKeysAreFreedFirst() {
        let migrated = apply(Migration.versionOneDefaults)
        #expect(migrated[.recordDisplay] == nil)
        #expect(migrated[.recordSetup] == Shortcut(.six, modifiers: [.control, .shift]))
        #expect(migrated[.recordRegion] == nil)
    }

    @Test("A shortcut the user switched off stays off")
    func disabledStaysDisabled() {
        var current = Migration.versionOneDefaults
        current[.captureArea] = nil
        #expect(apply(current)[.captureArea] == nil)
        #expect(!plan(current).contains { $0.0 == .captureArea })
    }

    @Test("It runs once")
    func runsOnce() throws {
        let suite = "kadr.tests.shortcutMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Migration.currentVersion, forKey: Migration.versionKey)
        Migration.runIfNeeded(defaults: defaults)
        #expect(defaults.integer(forKey: Migration.versionKey) == Migration.currentVersion)
    }
}
