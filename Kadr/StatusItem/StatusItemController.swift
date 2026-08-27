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
    private let restoreRecentlyClosed: () -> Void
    private let closeAllPins: () -> Void
    private let captureWithPicker: () -> Void
    private let showOnboarding: () -> Void
    private let checkForUpdates: () -> Void
    private let canCheckForUpdates: () -> Bool
    /// Extra menu items contributed by debug builds; empty in release.
    private let additionalItems: () -> [NSMenuItem]

    init(
        perform: @escaping (CaptureCommand) -> Void,
        openSettings: @escaping () -> Void,
        restoreRecentlyClosed: @escaping () -> Void = {},
        closeAllPins: @escaping () -> Void = {},
        captureWithPicker: @escaping () -> Void = {},
        showOnboarding: @escaping () -> Void = {},
        checkForUpdates: @escaping () -> Void = {},
        canCheckForUpdates: @escaping () -> Bool = { false },
        additionalItems: @escaping () -> [NSMenuItem] = { [] }
    ) {
        self.perform = perform
        self.openSettings = openSettings
        self.restoreRecentlyClosed = restoreRecentlyClosed
        self.closeAllPins = closeAllPins
        self.captureWithPicker = captureWithPicker
        self.showOnboarding = showOnboarding
        self.checkForUpdates = checkForUpdates
        self.canCheckForUpdates = canCheckForUpdates
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
        addCaptureItems(to: menu)
        addOverlayItems(to: menu)
        addApplicationItems(to: menu)
    }

    /// The capture commands, with their hotkey hints (docs/03 §8.1).
    private func addCaptureItems(to menu: NSMenu) {
        for command in CaptureCommand.menuCommands {
            let item = NSMenuItem(title: command.title, action: #selector(didSelectCapture(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.setShortcut(for: command.shortcutName)
            item.isEnabled = command.isAvailable
            menu.addItem(item)
        }

        // Always available, grant or not (docs/04 §4.1).
        let pickerItem = NSMenuItem(
            title: "Capture with the macOS Picker…",
            action: #selector(didSelectPickerCapture),
            keyEquivalent: ""
        )
        pickerItem.target = self
        menu.addItem(pickerItem)
    }

    /// Commands over the surfaces a capture produces (docs/03 §2, §4).
    private func addOverlayItems(to menu: NSMenu) {
        menu.addItem(.separator())

        let restoreItem = NSMenuItem(
            title: "Restore Recently Closed",
            action: #selector(didSelectRestore),
            keyEquivalent: "t"
        )
        restoreItem.keyEquivalentModifierMask = [.command, .shift]
        restoreItem.target = self
        menu.addItem(restoreItem)

        let closePinsItem = NSMenuItem(
            title: "Close All Pins",
            action: #selector(didSelectCloseAllPins),
            keyEquivalent: ""
        )
        closePinsItem.target = self
        menu.addItem(closePinsItem)
    }

    private func addApplicationItems(to menu: NSMenu) {
        let extras = additionalItems()
        if !extras.isEmpty {
            menu.addItem(.separator())
            for item in extras {
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(didSelectSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let onboardingItem = NSMenuItem(
            title: "Setup & Permissions…",
            action: #selector(didSelectOnboarding),
            keyEquivalent: ""
        )
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(didSelectCheckForUpdates),
            keyEquivalent: ""
        )
        updatesItem.target = self
        // Disabled while a check is already running, and in debug builds, where Sparkle
        // deliberately does nothing.
        updatesItem.isEnabled = canCheckForUpdates()
        menu.addItem(updatesItem)

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
    private func didSelectRestore() {
        restoreRecentlyClosed()
    }

    @objc
    private func didSelectCloseAllPins() {
        closeAllPins()
    }

    @objc
    private func didSelectPickerCapture() {
        captureWithPicker()
    }

    @objc
    private func didSelectOnboarding() {
        showOnboarding()
    }

    @objc
    private func didSelectCheckForUpdates() {
        checkForUpdates()
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
