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
    /// Nil when nothing is recording; otherwise the live recording's controls.
    private let recordingControls: () -> RecordingControls?
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
        recordingControls: @escaping () -> RecordingControls? = { nil },
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
        self.recordingControls = recordingControls
        self.additionalItems = additionalItems
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.toolTip = "Kadr"
        statusItem.behavior = .terminationOnRemoval
        showIdleIcon()

        // Items are built in menuNeedsUpdate, so launch pays for an empty menu only.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Icon states (docs/03 §8.1)

    /// The resting icon: a template image, so it follows the menu bar's appearance.
    func showIdleIcon() {
        let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kadr")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.title = ""
        statusItem.length = NSStatusItem.squareLength
    }

    /// While recording: a red dot and the elapsed time, so the state is unmistakable from
    /// across the room (docs/03 §8.1).
    ///
    /// Deliberately *not* a template image — red is the point, and a template would be
    /// rendered monochrome like everything else in the menu bar.
    func showRecordingIcon(elapsed: String, isPaused: Bool) {
        let name = isPaused ? "pause.circle.fill" : "record.circle"
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let icon = NSImage(systemSymbolName: name, accessibilityDescription: "Recording")?
            .withSymbolConfiguration(configuration)
        icon?.isTemplate = false

        statusItem.button?.image = icon
        statusItem.button?.title = " \(elapsed)"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.length = NSStatusItem.variableLength
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // A running recording takes over the top of the menu: stopping it is the only
        // thing the user is likely to want (docs/03 §1.8).
        if let controls = recordingControls() {
            addRecordingItems(controls, to: menu)
        }
        addCaptureItems(to: menu)
        addOverlayItems(to: menu)
        addApplicationItems(to: menu)
    }

    /// Controls for a recording in progress.
    private func addRecordingItems(_ controls: RecordingControls, to menu: NSMenu) {
        let status = NSMenuItem(title: "Recording — \(controls.elapsedText)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let stop = NSMenuItem(title: "Stop Recording", action: #selector(didSelectStopRecording), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)

        let pause = NSMenuItem(
            title: controls.isPaused ? "Resume Recording" : "Pause Recording",
            action: #selector(didSelectPauseRecording),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        let cancel = NSMenuItem(
            title: "Cancel Recording",
            action: #selector(didSelectCancelRecording),
            keyEquivalent: ""
        )
        cancel.target = self
        menu.addItem(cancel)

        menu.addItem(.separator())
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

        menu.addItem(.separator())

        for command in CaptureCommand.recordingCommands {
            let item = NSMenuItem(title: command.title, action: #selector(didSelectCapture(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.setShortcut(for: command.shortcutName)
            item.isEnabled = recordingControls() == nil
            menu.addItem(item)
        }
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
    private func didSelectStopRecording() {
        recordingControls()?.stop()
    }

    @objc
    private func didSelectPauseRecording() {
        recordingControls()?.togglePause()
    }

    @objc
    private func didSelectCancelRecording() {
        recordingControls()?.cancel()
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

/// What the menu needs to show and drive a recording in progress (docs/03 §1.8).
struct RecordingControls {
    let elapsedText: String
    let isPaused: Bool
    let stop: () -> Void
    let togglePause: () -> Void
    let cancel: () -> Void
}
