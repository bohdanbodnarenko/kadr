import AppKit
import KeyboardShortcuts
import os
import Shared

/// Five global shortcuts by default, not twenty-four (docs/03 §8.1).
///
/// A global hotkey is taken from every other app on the Mac for as long as Kadr runs. The
/// old set claimed ⌃⇧ plus most of the alphabet — keys IDEs and terminals bind — and ⇧⌘O,
/// which is Open Quickly in Xcode. The capture island already reaches every mode with a
/// single key once it is open, so only the commands people fire blind keep a default.
///
/// The capture island is ⇧⌘2: one key beside the system's own ⇧⌘3/4/5, so "the screenshot
/// keys" are one family and the island is the one to reach for when unsure. It is the
/// only default on ⇧⌘ — the system has nothing on 2 — and it toggles, and brings the
/// island back from the recorder (`AppDelegate.perform`). The direct captures mirror the
/// system's numbers with ⌃ in place of ⌘, which other apps rarely bind with a digit.
/// Everything else stays one click away in Settings ▸ Shortcuts.
/// `ShortcutDefaultsMigration` moves existing installs over.
extension KeyboardShortcuts.Name {
    static let allInOne = Self("allInOne", initial: .init(.two, modifiers: [.command, .shift]))
    static let captureArea = Self("captureArea", initial: .init(.four, modifiers: [.control, .shift]))
    static let captureWindow = Self("captureWindow")
    static let captureFullscreen = Self("captureFullscreen", initial: .init(.three, modifiers: [.control, .shift]))
    static let captureText = Self("captureText")
    static let capturePreviousArea = Self("capturePreviousArea")
    static let captureScrolling = Self("captureScrolling")
    static let pickColor = Self("pickColor")
    static let captureAreaAndCopy = Self("captureAreaAndCopy")
    static let captureAreaAndSave = Self("captureAreaAndSave")
    static let selfTimer = Self("selfTimer")
    static let recordRegion = Self("recordRegion")
    static let recordDisplay = Self("recordDisplay")
    /// Period, because it is the "stop" key everywhere else on the Mac — ⌘. has cancelled
    /// things since before the App Store.
    static let stopRecording = Self("stopRecording", initial: .init(.period, modifiers: [.control, .shift]))
    /// The discoverable path: one key for "I want to record something", which then asks what.
    static let recordSetup = Self("recordSetup", initial: .init(.six, modifiers: [.control, .shift]))
    static let freezeScreen = Self("freezeScreen")
    static let toggleDesktopIcons = Self("toggleDesktopIcons")
    static let closeAllOverlays = Self("closeAllOverlays")
    static let saveAllOverlays = Self("saveAllOverlays")
    static let hideOverlays = Self("hideOverlays")
    static let hidePins = Self("hidePins")
    static let pinClipboard = Self("pinClipboard")
    static let openHistory = Self("openHistory")
    static let openSaveFolder = Self("openSaveFolder")
}

extension CaptureCommand {
    var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .allInOne: .allInOne
        case .captureArea: .captureArea
        case .captureWindow: .captureWindow
        case .captureFullscreen: .captureFullscreen
        case .captureText: .captureText
        case .capturePreviousArea: .capturePreviousArea
        case .captureScrolling: .captureScrolling
        case .pickColor: .pickColor
        case .captureAreaAndCopy: .captureAreaAndCopy
        case .captureAreaAndSave: .captureAreaAndSave
        case .selfTimer: .selfTimer
        case .recordRegion: .recordRegion
        case .recordDisplay: .recordDisplay
        case .stopRecording: .stopRecording
        case .recordSetup: .recordSetup
        case .freezeScreen: .freezeScreen
        case .toggleDesktopIcons: .toggleDesktopIcons
        case .closeAllOverlays: .closeAllOverlays
        case .saveAllOverlays: .saveAllOverlays
        case .hideOverlays: .hideOverlays
        case .hidePins: .hidePins
        case .pinClipboard: .pinClipboard
        case .openHistory: .openHistory
        case .openSaveFolder: .openSaveFolder
        }
    }
}

/// Global hotkeys, via Carbon `RegisterEventHotKey` under KeyboardShortcuts (docs/04 §3.2).
///
/// Carbon hotkeys need no Accessibility permission and raise no TCC prompt, which is
/// why they are used instead of a `CGEventTap`. The tap appears exactly once later,
/// for the keystroke overlay while recording, behind its own permission ask.
@MainActor
final class HotkeyCenter {
    private let logger = KadrLog.logger(.hotkeys)
    private let perform: (CaptureCommand) -> Void

    init(perform: @escaping (CaptureCommand) -> Void) {
        self.perform = perform
    }

    let health = HotkeyHealth()

    /// Registers a handler for every command. Handlers fire on key *up* so a held
    /// shortcut cannot enqueue a burst of captures.
    func start() {
        ShortcutDefaultsMigration.runIfNeeded()
        health.probeAll()
        for command in CaptureCommand.allCases {
            KeyboardShortcuts.onKeyUp(for: command.shortcutName) { [weak self] in
                guard let self else { return }
                logger.info("Hotkey fired: \(command.rawValue, privacy: .public)")
                perform(command)
            }
        }
        let count = CaptureCommand.allCases.count
        logger.info("Registered \(count, privacy: .public) global hotkeys")
    }

    /// Rejects Option-only shortcuts and shortcuts already used by another Kadr command.
    ///
    /// Option-as-the-only-modifier hotkeys do not fire reliably on macOS 15
    /// (docs/04 §3.2), so the recorder refuses to record one rather than handing the
    /// user a shortcut that silently does nothing.
    nonisolated static func validate(
        _ shortcut: KeyboardShortcuts.Shortcut,
        for command: CaptureCommand = .allInOne,
        others: [CaptureCommand: KeyboardShortcuts.Shortcut] = [:]
    ) -> KeyboardShortcuts.ValidationResult {
        let modifiers = shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.option] {
            let reason = "Option-only shortcuts don’t fire reliably on macOS 15. Add ⌘, ⌃ or ⇧."
            return .disallow(reason: reason)
        }
        if let other = others.first(where: { $0.key != command && $0.value == shortcut }) {
            return .disallow(reason: "Already used by \(other.key.shortcutTitle)")
        }
        return .allow
    }

    @MainActor
    static func validator(
        for command: CaptureCommand
    ) -> (KeyboardShortcuts.Shortcut) -> KeyboardShortcuts.ValidationResult {
        { shortcut in
            var others: [CaptureCommand: KeyboardShortcuts.Shortcut] = [:]
            for candidate in CaptureCommand.allCases {
                if let value = KeyboardShortcuts.getShortcut(for: candidate.shortcutName) {
                    others[candidate] = value
                }
            }
            return validate(shortcut, for: command, others: others)
        }
    }

    @MainActor
    static func restoreDefault(for command: CaptureCommand) {
        KeyboardShortcuts.reset(command.shortcutName)
    }

    @MainActor
    static func restoreAll() {
        for command in CaptureCommand.allCases {
            KeyboardShortcuts.reset(command.shortcutName)
        }
    }
}
