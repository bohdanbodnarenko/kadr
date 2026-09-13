import AppKit
import HistoryKit
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
    /// Whether the status item is currently showing the recording icon (click = stop).
    private var showsRecordingIcon = false
    private let history: HistoryController?
    private let reopenFromHistory: (HistoryRecord) -> Void
    /// Overlay-menu items live in `StatusItemController+Overlay.swift`, so these
    /// cannot be `private` — that is file-scoped.
    let canRestore: () -> Bool
    private let openHistory: () -> Void
    /// How many recordings a crash left mid-edit, and how to reopen them (docs/09 U3.1).
    let unfinishedRecordings: () -> Int
    let recoverRecordings: () -> Void
    private let desktopIconsHidden: () -> Bool
    let overlayCardCount: () -> Int
    let overlaysAreHidden: () -> Bool
    let pinCount: () -> Int
    let pinsAreHidden: () -> Bool
    /// Images dropped on the menu-bar icon open in the editor (docs/03 §8.1).
    var openDroppedFile: ((URL) -> Void)?

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
        additionalItems: @escaping () -> [NSMenuItem] = { [] },
        history: HistoryController? = nil,
        reopenFromHistory: @escaping (HistoryRecord) -> Void = { _ in },
        canRestore: @escaping () -> Bool = { true },
        openHistory: @escaping () -> Void = {},
        unfinishedRecordings: @escaping () -> Int = { 0 },
        recoverRecordings: @escaping () -> Void = {},
        desktopIconsHidden: @escaping () -> Bool = { false },
        overlayCardCount: @escaping () -> Int = { 0 },
        overlaysAreHidden: @escaping () -> Bool = { false },
        pinCount: @escaping () -> Int = { 0 },
        pinsAreHidden: @escaping () -> Bool = { false }
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
        self.history = history
        self.reopenFromHistory = reopenFromHistory
        self.canRestore = canRestore
        self.openHistory = openHistory
        self.unfinishedRecordings = unfinishedRecordings
        self.recoverRecordings = recoverRecordings
        self.desktopIconsHidden = desktopIconsHidden
        self.overlayCardCount = overlayCardCount
        self.overlaysAreHidden = overlaysAreHidden
        self.pinCount = pinCount
        self.pinsAreHidden = pinsAreHidden
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.toolTip = "Kadr"
        statusItem.behavior = .terminationOnRemoval
        showIdleIcon()
        attachDropTarget()

        // Items are built in menuNeedsUpdate, so launch pays for an empty menu only.
        menu.autoenablesItems = false
        menu.delegate = self
        attachIdleMenu()
    }

    /// Drop a still or `.kadr` on the icon to annotate it (docs/03 §8.1).
    private func attachDropTarget() {
        guard let button = statusItem.button else { return }
        let drop = StatusItemDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onDrop = { [weak self] url in self?.openDroppedFile?(url) }
        button.addSubview(drop)
    }

    // MARK: - Icon states (docs/03 §8.1)

    /// The resting icon: a template image, so it follows the menu bar's appearance.
    func showIdleIcon() {
        showsRecordingIcon = false
        let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kadr")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.title = ""
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.toolTip = "Kadr"
        attachIdleMenu()
    }

    /// While recording: a red dot and the elapsed time, so the state is unmistakable from
    /// across the room (docs/03 §8.1).
    ///
    /// Deliberately *not* a template image — red is the point, and a template would be
    /// rendered monochrome like everything else in the menu bar.
    func showRecordingIcon(elapsed: String, isPaused: Bool) {
        showsRecordingIcon = true
        let name = isPaused ? "pause.circle.fill" : "record.circle"
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let icon = NSImage(systemSymbolName: name, accessibilityDescription: "Recording")?
            .withSymbolConfiguration(configuration)
        icon?.isTemplate = false

        statusItem.button?.image = icon
        statusItem.button?.title = " \(elapsed)"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.toolTip = "Click to stop · right-click for pause and discard"
        attachRecordingClick()
    }

    /// Idle: Option-click opens All-in-One; otherwise the menu opens (docs/03 §8.1).
    private func attachIdleMenu() {
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(didClickIdleStatusItem)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Recording: a click stops, because that is the only thing the user is likely to want
    /// (docs/03 §1.8). Right-click still opens the menu for pause and discard.
    private func attachRecordingClick() {
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(didClickStatusItem)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc
    private func didClickIdleStatusItem() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            popIdleMenu()
            return
        }
        if event?.modifierFlags.contains(.option) == true {
            perform(.allInOne)
            return
        }
        popIdleMenu()
    }

    private func popIdleMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        attachIdleMenu()
    }

    @objc
    private func didClickStatusItem() {
        guard showsRecordingIcon else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            popRecordingMenu()
            return
        }
        recordingControls()?.stop()
    }

    private func popRecordingMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        attachRecordingClick()
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
        addHistoryItems(to: menu)
        addOverlayItems(to: menu)
        addApplicationItems(to: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        history?.purgeStripThumbnails()
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

        let restart = NSMenuItem(
            title: "Restart Recording",
            action: #selector(didSelectRestartRecording),
            keyEquivalent: ""
        )
        restart.target = self
        menu.addItem(restart)

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
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for command in CaptureCommand.utilityCommands {
            let item = NSMenuItem(title: command.title, action: #selector(didSelectCapture(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.setShortcut(for: command.shortcutName)
            if command == .toggleDesktopIcons {
                let hidden = desktopIconsHidden()
                item.title = hidden ? "Show Desktop Icons" : "Hide Desktop Icons"
                item.state = hidden ? .on : .off
            }
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

    /// Last-8 thumbnail strip and the History window command (docs/03 §5, §8.1).
    private func addHistoryItems(to menu: NSMenu) {
        let recent = Array(history?.recent.prefix(HistoryController.menuStripCount) ?? [])
        if !recent.isEmpty {
            menu.addItem(.separator())
            let strip = HistoryStripView(frame: .zero)
            strip.update(records: recent) { [weak self] record in
                guard let cgImage = self?.history?.thumbnail(for: record, maxPixelSize: 112, scope: .strip) else {
                    return nil
                }
                return NSImage(cgImage: cgImage, size: HistoryStripView.thumbnailSize)
            }
            strip.onSelect = { [weak self] id in
                guard let record = self?.history?.record(id: id) else { return }
                self?.reopenFromHistory(record)
            }
            let item = NSMenuItem()
            item.view = strip
            menu.addItem(item)
        }
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
    func didSelectCapture(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let command = CaptureCommand(rawValue: rawValue)
        else { return }
        perform(command)
    }

    @objc
    func didSelectRestore() {
        restoreRecentlyClosed()
    }

    @objc
    func didSelectHistory() {
        openHistory()
    }

    @objc
    func didSelectCloseAllPins() {
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
    private func didSelectRestartRecording() {
        recordingControls()?.restart()
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
    var restart: () -> Void = {}
    /// 0…1 loudness for the control-bar meter (CleanShot §13.3).
    var audioLevel: Float = 0
    /// True when the microphone is on but has not picked up anything this take.
    var microphoneIsSilent: Bool = false
}
