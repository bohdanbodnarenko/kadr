import AppKit
import HistoryKit
import KeyboardShortcuts
import os
import OverlayKit
import Shared

/// The menu bar item and its menu (docs/03 §8.1, docs/04 §3.1).
///
/// `NSStatusItem` + a plain `NSMenu`, not `MenuBarExtra`: the recording-state icon,
/// drag-onto-icon and click-for-island / right-click-for-menu behaviours are painful or
/// impossible with the SwiftUI scene, and a plain menu is the cheapest idle path
/// there is — nothing is built until the user actually opens it.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let statusItem: NSStatusItem
    let menu = NSMenu()
    private let logger = KadrLog.logger(.app)

    let perform: (CaptureCommand) -> Void
    private let openSettings: () -> Void
    let restoreRecentlyClosed: () -> Void
    private let closeAllPins: () -> Void
    private let showOnboarding: () -> Void
    /// Whether a required permission is missing, so the menu offers the setup assistant.
    private let needsSetup: () -> Bool
    /// Nil when nothing is recording; otherwise the live recording's controls.
    private let recordingControls: () -> RecordingControls?
    /// Extra menu items contributed by debug builds; empty in release.
    let additionalItems: () -> [NSMenuItem]
    /// Whether ⌥ was held as the menu opened, which adds the diagnostics rows.
    var showsTesterItems = false
    /// Whether the status item is currently showing the recording icon (click = stop).
    var showsRecordingIcon = false
    /// The user's "show in menu bar" choice. The item is shown anyway while a recording
    /// runs: a take must never run with no Kadr indicator and no Stop (docs/18 REC-2).
    var userWantsMenuBarIcon = true
    /// KVO for the user dragging the icon out of the menu bar (docs/16 APP-2).
    var visibilityObservation: NSKeyValueObservation?
    /// The settings-driven visibility observer, kept so it is registered once and can be
    /// removed.
    var menuBarVisibilityToken: (any NSObjectProtocol)?
    /// Symbol images by `StatusItemAppearance.imageKey`, built once each (PRD §8).
    var iconCache: [String: NSImage] = [:]
    /// The image currently on the button, so an unchanged one is not reassigned.
    var appliedIconKey: String?
    /// The recovery row in the open menu, so a count that arrives late can update it.
    weak var recoveryItem: NSMenuItem?
    /// Fills the strip with thumbnails after the menu is up.
    var thumbnailFillTask: Task<Void, Never>?
    let history: HistoryController?
    let reopenFromHistory: (HistoryRecord) -> Void
    /// Overlay-menu items live in `StatusItemController+Overlay.swift`, so these
    /// cannot be `private` — that is file-scoped.
    let canRestore: () -> Bool
    let openHistory: () -> Void
    /// How many recordings a crash left mid-edit, and how to reopen them (docs/09 U3.1).
    let unfinishedRecordings: () -> Int
    /// Recounts off the main thread and reports the new count on it.
    let refreshUnfinishedRecordings: (@escaping (Int) -> Void) -> Void
    let recoverRecordings: () -> Void
    let overlayCardCount: () -> Int
    let overlaysAreHidden: () -> Bool
    let pinCount: () -> Int
    let pinsAreHidden: () -> Bool
    /// A version a background check found and left for the menu to mention (docs/17 T-REL-4).
    let availableUpdate: () -> String?
    let installUpdate: () -> Void
    /// Held-⌥ rows for testers (docs/17 T-DIAG-1).
    let exportDiagnostics: () -> Void
    let reportProblem: () -> Void
    /// Images dropped on the menu-bar icon open in the editor (docs/03 §8.1).
    var openDroppedFile: ((URL) -> Void)?
    /// Writes the menu-bar visibility setting when the user removes the icon (docs/16 APP-2).
    var onMenuBarVisibilityChange: ((Bool) -> Void)?
    /// Any click on the idle icon, so the first-run hint under it can go.
    var onIconClicked: (() -> Void)?

    init(
        perform: @escaping (CaptureCommand) -> Void,
        openSettings: @escaping () -> Void,
        restoreRecentlyClosed: @escaping () -> Void = {},
        closeAllPins: @escaping () -> Void = {},
        showOnboarding: @escaping () -> Void = {},
        needsSetup: @escaping () -> Bool = { false },
        recordingControls: @escaping () -> RecordingControls? = { nil },
        additionalItems: @escaping () -> [NSMenuItem] = { [] },
        history: HistoryController? = nil,
        reopenFromHistory: @escaping (HistoryRecord) -> Void = { _ in },
        canRestore: @escaping () -> Bool = { true },
        openHistory: @escaping () -> Void = {},
        unfinishedRecordings: @escaping () -> Int = { 0 },
        refreshUnfinishedRecordings: @escaping (@escaping (Int) -> Void) -> Void = { _ in },
        recoverRecordings: @escaping () -> Void = {},
        overlayCardCount: @escaping () -> Int = { 0 },
        overlaysAreHidden: @escaping () -> Bool = { false },
        pinCount: @escaping () -> Int = { 0 },
        pinsAreHidden: @escaping () -> Bool = { false },
        availableUpdate: @escaping () -> String? = { nil },
        installUpdate: @escaping () -> Void = {},
        exportDiagnostics: @escaping () -> Void = {},
        reportProblem: @escaping () -> Void = {}
    ) {
        self.perform = perform
        self.openSettings = openSettings
        self.restoreRecentlyClosed = restoreRecentlyClosed
        self.closeAllPins = closeAllPins
        self.showOnboarding = showOnboarding
        self.needsSetup = needsSetup
        self.recordingControls = recordingControls
        self.additionalItems = additionalItems
        self.history = history
        self.reopenFromHistory = reopenFromHistory
        self.canRestore = canRestore
        self.openHistory = openHistory
        self.unfinishedRecordings = unfinishedRecordings
        self.refreshUnfinishedRecordings = refreshUnfinishedRecordings
        self.recoverRecordings = recoverRecordings
        self.overlayCardCount = overlayCardCount
        self.overlaysAreHidden = overlaysAreHidden
        self.pinCount = pinCount
        self.pinsAreHidden = pinsAreHidden
        self.availableUpdate = availableUpdate
        self.installUpdate = installUpdate
        self.exportDiagnostics = exportDiagnostics
        self.reportProblem = reportProblem
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.toolTip = "Kadr"
        statusItem.behavior = .removalAllowed
        statusItem.isVisible = true
        showIdleIcon()
        attachDropTarget()
        installMenuAccessibilityAction()

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
        // ⌃-click is the Mac's secondary click. Treating it as a plain click stopped the take
        // for anyone who reaches the menu that way (docs/03 §8.1, docs/17 T-REC-11).
        let modifiers = event?.modifierFlags ?? []
        if event?.type == .rightMouseUp || !modifiers.isDisjoint(with: [.option, .control]) {
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

    /// A short menu: the live recording, recent work, what needs attention, and the app
    /// (docs/03 §8.1, docs/14 UX-08).
    ///
    /// Capturing is the island's job — a click on the icon opens it — so no capture mode,
    /// utility or overlay command is listed here. The menu used to carry all of them and ran
    /// past twenty rows before History. What is left is what the island cannot do, and a
    /// group whose rows could not do anything right now is absent rather than greyed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menuNeedsUpdate(menu, optionHeld: NSEvent.modifierFlags.contains(.option))
    }

    /// The build, with the ⌥ state passed in so a test can ask for either menu.
    func menuNeedsUpdate(_ menu: NSMenu, optionHeld: Bool) {
        showsTesterItems = optionHeld
        menu.removeAllItems()
        if let controls = recordingControls() {
            addRecordingItems(controls, to: menu)
        }
        addHistoryItems(to: menu)
        addOverlayItems(to: menu)
        addApplicationItems(to: menu)
    }

    /// Leaves the strip's thumbnails cached (docs/10 R2.4).
    ///
    /// They used to be purged here, so the cache the strip has for exactly this purpose
    /// never once served a hit: every open decoded the same eight images again. Eight
    /// 112 px thumbnails are well under the strip's own 1.5 MB budget, and the cache still
    /// empties itself under memory pressure.
    func menuDidClose(_ menu: NSMenu) {
        thumbnailFillTask?.cancel()
        thumbnailFillTask = nil
    }

    /// One separator between groups, and never one at the top or two in a row.
    static func addGroupSeparator(to menu: NSMenu) {
        guard let last = menu.items.last, !last.isSeparatorItem else { return }
        menu.addItem(.separator())
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

    /// The live recording, first, because while one runs it is the only thing that matters
    /// (docs/03 §1.8, docs/14 UX-08).
    private func addRecordingItems(_ controls: RecordingControls, to menu: NSMenu) {
        // A take being saved can no longer be stopped, paused, restarted or discarded;
        // offering those rows asked for confirmation and then did nothing (docs/18 REC-12).
        guard !controls.isSaving else {
            let saving = NSMenuItem(title: "Saving Recording…", action: nil, keyEquivalent: "")
            saving.isEnabled = false
            menu.addItem(saving)
            return
        }
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
            title: "Restart Recording…",
            action: #selector(didSelectRestartRecording),
            keyEquivalent: ""
        )
        restart.target = self
        menu.addItem(restart)

        // Its own group: the one row that throws the take away should not sit flush
        // against Pause, one slip of the pointer from it (docs/17 T-SH-6).
        menu.addItem(.separator())
        let cancel = NSMenuItem(
            title: "Discard Recording…",
            action: #selector(didSelectCancelRecording),
            keyEquivalent: ""
        )
        cancel.target = self
        menu.addItem(cancel)
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
        guard Self.confirmDestructive(
            title: String(localized: "Restart the recording?"),
            detail: String(localized: "What has been recorded so far is deleted and a new take starts."),
            action: String(localized: "Restart")
        ) else { return }
        recordingControls()?.restart()
    }

    @objc
    private func didSelectCancelRecording() {
        guard Self.confirmDestructive(
            title: String(localized: "Discard the recording?"),
            detail: String(localized: "The take is deleted and cannot be recovered."),
            action: String(localized: "Discard")
        ) else { return }
        recordingControls()?.cancel()
    }

    /// One click in a menu used to throw away a take with no way back (docs/17 T-SH-6).
    /// Undo is impossible here — the footage is gone — so this asks, with the destructive
    /// button marked and Cancel as the default Return answers (HIG › Alerts).
    static func confirmDestructive(title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Cancel"))
        let destructive = alert.addButton(withTitle: action)
        destructive.hasDestructiveAction = true
        let answer = ActivationJuggler.shared.withTemporaryActivation(
            returningTo: ActivationJuggler.returnTarget()
        ) { alert.runModal() }
        return answer == .alertSecondButtonReturn
    }

    @objc
    func didSelectOnboarding() {
        showOnboarding()
    }

    var isSetupNeeded: Bool {
        needsSetup()
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
    /// True when the take asked for a microphone and records without one (docs/18 REC-1).
    var microphoneDropped: Bool = false
    /// Transient status while a take is interrupted or the transport is settling.
    var notice: String?
    var isTransitioning: Bool = false
    /// The take has stopped and its file is being finalised (docs/17 T-REC-4).
    var isSaving: Bool = false
}
