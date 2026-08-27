import AppKit
import KeyboardShortcuts
import os
import Shared

/// The menu bar item and its menu (docs/03 §8.1, docs/04 §3.1).
///
/// `NSStatusItem` + a plain `NSMenu`, not `MenuBarExtra`: the recording-state icon,
/// drag-onto-icon and ⌥-click behaviours coming in later milestones are painful or
/// impossible with the SwiftUI scene, and a plain menu is the cheapest idle path
/// there is — nothing is built until the user actually opens it.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let logger = KadrLog.logger(.app)

    private let perform: (CaptureCommand) -> Void
    private let openSettings: () -> Void
    /// Extra menu items contributed by debug builds; empty in release.
    private let additionalItems: () -> [NSMenuItem]

    init(
        perform: @escaping (CaptureCommand) -> Void,
        openSettings: @escaping () -> Void,
        additionalItems: @escaping () -> [NSMenuItem] = { [] }
    ) {
        self.perform = perform
        self.openSettings = openSettings
        self.additionalItems = additionalItems
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kadr")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "Kadr"
        statusItem.behavior = .terminationOnRemoval

        // Items are built in menuNeedsUpdate, so launch pays for an empty menu only.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for command in CaptureCommand.menuCommands {
            let item = NSMenuItem(title: command.title, action: #selector(didSelectCapture(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.setShortcut(for: command.shortcutName)
            item.isEnabled = command.isAvailable
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(didSelectSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        // Sparkle is wired up in M11; until then this advertises the update path honestly.
        updatesItem.isEnabled = false
        menu.addItem(updatesItem)

        let extras = additionalItems()
        if !extras.isEmpty {
            menu.addItem(.separator())
            for item in extras {
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Kadr", action: #selector(didSelectQuit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc
    private func didSelectCapture(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let command = CaptureCommand(rawValue: rawValue)
        else { return }
        perform(command)
    }

    @objc
    private func didSelectSettings() {
        openSettings()
    }

    @objc
    private func didSelectQuit() {
        logger.info("Quit from the status menu")
        NSApp.terminate(nil)
    }
}
