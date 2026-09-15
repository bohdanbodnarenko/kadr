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
    let statusItem: NSStatusItem
    let menu = NSMenu()
    private let logger = KadrLog.logger(.app)

    let perform: (CaptureCommand) -> Void
    private let openSettings: () -> Void
    private let restoreRecentlyClosed: () -> Void
    private let closeAllPins: () -> Void
    private let captureWithPicker: () -> Void
    private let showOnboarding: () -> Void
    private let checkForUpdates: () -> Void
    let canCheckForUpdates: () -> Bool
    /// Nil when nothing is recording; otherwise the live recording's controls.
    private let recordingControls: () -> RecordingControls?
    /// Extra menu items contributed by debug builds; empty in release.
    let additionalItems: () -> [NSMenuItem]
    /// Whether the status item is currently showing the recording icon (click = stop).
    var showsRecordingIcon = false
    /// KVO for the user dragging the icon out of the menu bar (docs/16 APP-2).
    var visibilityObservation: NSKeyValueObservation?
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
    /// Writes the menu-bar visibility setting when the user removes the icon (docs/16 APP-2).
    var onMenuBarVisibilityChange: ((Bool) -> Void)?

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
        statusItem.behavior = .removalAllowed
        statusItem.isVisible = true
        showIdleIcon()
        attachDropTarget()

        // Items are built in menuNeedsUpdate, so launch pays for an empty menu only.
        menu.autoenablesItems = false
        menu.delegate = self
        attachIdleMenu()
        observeMenuBarVisibility()
    }

    /// Drop a still or `.kadr` on the icon to annotate it (docs/03 §8.1).
    private func attachDropTarget() {
        guard let button = statusItem.button else { return }
        let drop = StatusItemDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onDrop = { [weak self] url in self?.openDroppedFile?(url) }
        button.addSubview(drop)
    }

    @objc
    func didClickStatusItem() {
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

    /// Groups the menu by task, with one separator between groups (docs/14 UX-08).
    ///
    /// Capture modes, utilities, the live recording, recent work, the surfaces a capture
    /// produced, setup, updates, quit. A group whose commands cannot do anything right now
    /// is absent rather than present and greyed: a disabled row with no explanation is a
    /// puzzle, and the menu is rebuilt on every open anyway, so absence costs nothing.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addCaptureItems(to: menu)
        addUtilityItems(to: menu)
        if let controls = recordingControls() {
            addRecordingItems(controls, to: menu)
        }
        addHistoryItems(to: menu)
        addOverlayItems(to: menu)
        addApplicationItems(to: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        history?.purgeStripThumbnails()
    }

    /// Builds one command row: title, glyph, target, right-aligned shortcut.
    ///
    /// The shortcut goes on through `keyEquivalent`, never into the title. AppKit
    /// right-aligns a key equivalent and VoiceOver reads it as a shortcut; text in the
    /// title is read as part of the command's name.
    func makeCommandItem(_ command: CaptureCommand, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(
            title: title ?? command.title,
            action: #selector(didSelectCapture(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = command.rawValue
        item.setShortcut(for: command.shortcutName)
        if let symbol = command.menuSymbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    /// Group 1 — how to take a capture (docs/03 §8.1).
    ///
    /// The two record commands belong here: starting a recording is a capture mode, not a
    /// recording control. While one is running they are gone, replaced by the group that
    /// can actually stop it.
    private func addCaptureItems(to menu: NSMenu) {
        for command in CaptureCommand.menuCommands {
            menu.addItem(makeCommandItem(command))
        }

        guard recordingControls() == nil else { return }
        for command in CaptureCommand.recordingCommands {
            menu.addItem(makeCommandItem(command))
        }
    }

    /// Group 2 — things done to the screen before or instead of a capture (docs/03 §7).
    private func addUtilityItems(to menu: NSMenu) {
        menu.addItem(.separator())

        for command in CaptureCommand.utilityCommands {
            let hidden = desktopIconsHidden()
            let item = command == .toggleDesktopIcons
                ? makeCommandItem(command, title: hidden ? "Show Desktop Icons" : "Hide Desktop Icons")
                : makeCommandItem(command)
            if command == .toggleDesktopIcons {
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
    }

    /// Group 3 — only while something is recording (docs/03 §1.8, docs/14 UX-08).
    private func addRecordingItems(_ controls: RecordingControls, to menu: NSMenu) {
        menu.addItem(.separator())

        let status = NSMenuItem(
            title: controls.isPaused
                ? "Recording paused — \(controls.elapsedText)"
                : "Recording — \(controls.elapsedText)",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        let stop = NSMenuItem(title: "Stop Recording", action: #selector(didSelectStopRecording), keyEquivalent: "")
        stop.target = self
        stop.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
        stop.setShortcut(for: CaptureCommand.stopRecording.shortcutName)
        menu.addItem(stop)

        let pause = NSMenuItem(
            title: controls.isPaused ? "Resume Recording" : "Pause Recording",
            action: #selector(didSelectPauseRecording),
            keyEquivalent: ""
        )
        pause.target = self
        pause.image = NSImage(
            systemSymbolName: controls.isPaused ? "play.circle" : "pause.circle",
            accessibilityDescription: nil
        )
        menu.addItem(pause)

        let restart = NSMenuItem(
            title: "Restart Recording",
            action: #selector(didSelectRestartRecording),
            keyEquivalent: ""
        )
        restart.target = self
        menu.addItem(restart)

        let cancel = NSMenuItem(
            title: "Discard Recording",
            action: #selector(didSelectCancelRecording),
            keyEquivalent: ""
        )
        cancel.target = self
        menu.addItem(cancel)
    }

    /// Group 4 — the last few captures, and the window that holds the rest
    /// (docs/03 §5, §8.1).
    private func addHistoryItems(to menu: NSMenu) {
        let recent = Array(history?.recent.prefix(HistoryController.menuStripCount) ?? [])
        menu.addItem(.separator())

        if !recent.isEmpty {
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

            let recentMenu = NSMenu()
            for record in recent {
                let row = NSMenuItem(
                    title: record.originalFilename,
                    action: #selector(didSelectRecent(_:)),
                    keyEquivalent: ""
                )
                row.target = self
                row.representedObject = record.id
                if let cgImage = history?.thumbnail(for: record, maxPixelSize: 32, scope: .strip) {
                    let icon = NSImage(cgImage: cgImage, size: NSSize(width: 16, height: 16))
                    row.image = icon
                }
                recentMenu.addItem(row)
            }
            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            recentItem.submenu = recentMenu
            menu.addItem(recentItem)
        }

        let historyItem = NSMenuItem(title: "History…", action: #selector(didSelectHistory), keyEquivalent: "l")
        historyItem.keyEquivalentModifierMask = [.command, .shift]
        historyItem.target = self
        historyItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        menu.addItem(historyItem)

        let folderItem = NSMenuItem(
            title: "Open Capture Folder",
            action: #selector(didSelectOpenSaveFolder),
            keyEquivalent: ""
        )
        folderItem.target = self
        folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(folderItem)

        if canRestore() {
            let restoreItem = NSMenuItem(
                title: "Restore Recently Closed",
                action: #selector(didSelectRestore),
                keyEquivalent: "t"
            )
            restoreItem.keyEquivalentModifierMask = [.command, .shift]
            restoreItem.target = self
            menu.addItem(restoreItem)
        }

        addRecoveryItem(to: menu)
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
    func didSelectOpenSaveFolder() {
        perform(.openSaveFolder)
    }

    @objc
    func didSelectRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let record = history?.record(id: id)
        else {
            return
        }
        reopenFromHistory(record)
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
    func didSelectOnboarding() {
        showOnboarding()
    }

    @objc
    func didSelectCheckForUpdates() {
        checkForUpdates()
    }

    @objc
    func didSelectSettings() {
        openSettings()
    }

    @objc
    func didSelectQuit() {
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
    /// Transient status while a take is interrupted or the transport is settling.
    var notice: String?
    var isTransitioning: Bool = false
}
