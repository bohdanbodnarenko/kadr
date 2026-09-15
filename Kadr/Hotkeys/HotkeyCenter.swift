import AppKit
import KeyboardShortcuts
import os
import Shared

extension KeyboardShortcuts.Name {
    // Defaults deliberately avoid ⇧⌘3/4/5, which belong to the system screenshot UI —
    // Kadr should sit alongside it, not silently fail to register over the top of it.
    static let allInOne = Self("allInOne", initial: .init(.one, modifiers: [.control, .shift]))
    static let captureArea = Self("captureArea", initial: .init(.a, modifiers: [.control, .shift]))
    static let captureWindow = Self("captureWindow", initial: .init(.w, modifiers: [.control, .shift]))
    static let captureFullscreen = Self("captureFullscreen", initial: .init(.f, modifiers: [.control, .shift]))
    static let captureText = Self("captureText", initial: .init(.t, modifiers: [.control, .shift]))
    static let capturePreviousArea = Self("capturePreviousArea", initial: .init(.r, modifiers: [.control, .shift]))
    static let captureScrolling = Self("captureScrolling", initial: .init(.s, modifiers: [.control, .shift]))
    static let pickColor = Self("pickColor", initial: .init(.p, modifiers: [.control, .shift]))
    static let captureAreaAndCopy = Self(
        "captureAreaAndCopy",
        initial: .init(.c, modifiers: [.control, .option, .shift])
    )
    static let captureAreaAndSave = Self(
        "captureAreaAndSave",
        initial: .init(.four, modifiers: [.control, .option, .shift])
    )
    static let selfTimer = Self("selfTimer", initial: .init(.eight, modifiers: [.control, .shift]))
    static let recordRegion = Self("recordRegion", initial: .init(.five, modifiers: [.control, .shift]))
    static let recordDisplay = Self("recordDisplay", initial: .init(.six, modifiers: [.control, .shift]))
    // Period, because it is the "stop" key everywhere else on the Mac — ⌘. has cancelled
    // things since before the App Store.
    static let stopRecording = Self("stopRecording", initial: .init(.period, modifiers: [.control, .shift]))
    // The discoverable path: one key for "I want to record something", which then asks what.
    static let recordSetup = Self("recordSetup", initial: .init(.r, modifiers: [.control, .shift, .option]))
    static let freezeScreen = Self("freezeScreen", initial: .init(.z, modifiers: [.control, .shift]))
    static let toggleDesktopIcons = Self("toggleDesktopIcons", initial: .init(.h, modifiers: [.control, .shift]))
    static let closeAllOverlays = Self(
        "closeAllOverlays",
        initial: .init(.w, modifiers: [.control, .option, .shift])
    )
    static let saveAllOverlays = Self(
        "saveAllOverlays",
        initial: .init(.a, modifiers: [.control, .option, .shift])
    )
    static let hideOverlays = Self("hideOverlays", initial: .init(.o, modifiers: [.control, .shift]))
    static let hidePins = Self("hidePins", initial: .init(.u, modifiers: [.control, .shift]))
    static let pinClipboard = Self("pinClipboard", initial: .init(.y, modifiers: [.control, .shift]))
    static let openHistory = Self("openHistory", initial: .init(.l, modifiers: [.command, .shift]))
    static let openSaveFolder = Self("openSaveFolder", initial: .init(.o, modifiers: [.command, .shift]))
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
