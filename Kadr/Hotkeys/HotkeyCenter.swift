import AppKit
import KeyboardShortcuts
import os
import Shared

extension KeyboardShortcuts.Name {
    // Defaults deliberately avoid ⇧⌘3/4/5, which belong to the system screenshot UI —
    // Kadr should sit alongside it, not silently fail to register over the top of it.
    static let captureArea = Self("captureArea", initial: .init(.a, modifiers: [.control, .shift]))
    static let captureWindow = Self("captureWindow", initial: .init(.w, modifiers: [.control, .shift]))
    static let captureFullscreen = Self("captureFullscreen", initial: .init(.f, modifiers: [.control, .shift]))
    static let captureText = Self("captureText", initial: .init(.t, modifiers: [.control, .shift]))
    static let capturePreviousArea = Self("capturePreviousArea", initial: .init(.r, modifiers: [.control, .shift]))
    static let captureScrolling = Self("captureScrolling", initial: .init(.s, modifiers: [.control, .shift]))
    static let recordRegion = Self("recordRegion", initial: .init(.five, modifiers: [.control, .shift]))
    static let recordDisplay = Self("recordDisplay", initial: .init(.six, modifiers: [.control, .shift]))
}

extension CaptureCommand {
    var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .captureArea: .captureArea
        case .captureWindow: .captureWindow
        case .captureFullscreen: .captureFullscreen
        case .captureText: .captureText
        case .capturePreviousArea: .capturePreviousArea
        case .captureScrolling: .captureScrolling
        case .recordRegion: .recordRegion
        case .recordDisplay: .recordDisplay
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

    /// Registers a handler for every command. Handlers fire on key *up* so a held
    /// shortcut cannot enqueue a burst of captures.
    func start() {
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

    /// Rejects Option-only shortcuts in the recorder.
    ///
    /// Option-as-the-only-modifier hotkeys do not fire reliably on macOS 15
    /// (docs/04 §3.2), so the recorder refuses to record one rather than handing the
    /// user a shortcut that silently does nothing.
    nonisolated static func validate(
        _ shortcut: KeyboardShortcuts.Shortcut
    ) -> KeyboardShortcuts.ValidationResult {
        let modifiers = shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.option] else { return .allow }
        let reason = "Option-only shortcuts don’t fire reliably on macOS 15. Add ⌘, ⌃ or ⇧."
        return .disallow(reason: reason)
    }
}
