import AppKit
import KeyboardShortcuts

/// Moves an existing install onto the current default shortcuts (docs/03 §8.1).
///
/// KeyboardShortcuts writes a name's initial shortcut into `UserDefaults` the first time
/// the name is touched, so every install that ran an older build has that build's defaults
/// saved as if the user had chosen them. Changing the `initial:` values alone would
/// therefore change nothing for anybody who already has Kadr.
///
/// The rule is the one a user would expect: a shortcut still equal to a default some
/// earlier build shipped was never chosen, so it moves to the current default — or goes
/// away if the command no longer has one. A shortcut the user recorded themselves is left
/// exactly as it is. A new default already held by another command is not handed out, and
/// the command keeps the shortcut it had rather than losing it.
///
/// Runs once per version, gated by a number in `UserDefaults`:
/// 1 → the original twenty-four; 2 → five on ⌃⇧ digits; 3 → the island moves to ⇧⌘2.
enum ShortcutDefaultsMigration {
    static let versionKey = "com.bohdanbodnarenko.kadr.shortcutDefaultsVersion"
    static let currentVersion = 3

    /// The defaults the first builds shipped, by command.
    static let versionOneDefaults: [CaptureCommand: KeyboardShortcuts.Shortcut] = [
        .allInOne: .init(.one, modifiers: [.control, .shift]),
        .captureArea: .init(.a, modifiers: [.control, .shift]),
        .captureWindow: .init(.w, modifiers: [.control, .shift]),
        .captureFullscreen: .init(.f, modifiers: [.control, .shift]),
        .captureText: .init(.t, modifiers: [.control, .shift]),
        .capturePreviousArea: .init(.r, modifiers: [.control, .shift]),
        .captureScrolling: .init(.s, modifiers: [.control, .shift]),
        .pickColor: .init(.p, modifiers: [.control, .shift]),
        .captureAreaAndCopy: .init(.c, modifiers: [.control, .option, .shift]),
        .captureAreaAndSave: .init(.four, modifiers: [.control, .option, .shift]),
        .selfTimer: .init(.eight, modifiers: [.control, .shift]),
        .recordRegion: .init(.five, modifiers: [.control, .shift]),
        .recordDisplay: .init(.six, modifiers: [.control, .shift]),
        .stopRecording: .init(.period, modifiers: [.control, .shift]),
        .recordSetup: .init(.r, modifiers: [.control, .shift, .option]),
        .freezeScreen: .init(.z, modifiers: [.control, .shift]),
        .toggleDesktopIcons: .init(.h, modifiers: [.control, .shift]),
        .closeAllOverlays: .init(.w, modifiers: [.control, .option, .shift]),
        .saveAllOverlays: .init(.a, modifiers: [.control, .option, .shift]),
        .hideOverlays: .init(.o, modifiers: [.control, .shift]),
        .hidePins: .init(.u, modifiers: [.control, .shift]),
        .pinClipboard: .init(.y, modifiers: [.control, .shift]),
        .openHistory: .init(.l, modifiers: [.command, .shift]),
        .openSaveFolder: .init(.o, modifiers: [.command, .shift])
    ]

    /// The five defaults version 2 shipped.
    static let versionTwoDefaults: [CaptureCommand: KeyboardShortcuts.Shortcut] = [
        .allInOne: .init(.five, modifiers: [.control, .shift]),
        .captureArea: .init(.four, modifiers: [.control, .shift]),
        .captureFullscreen: .init(.three, modifiers: [.control, .shift]),
        .recordSetup: .init(.six, modifiers: [.control, .shift]),
        .stopRecording: .init(.period, modifiers: [.control, .shift])
    ]

    /// Every default a command has ever shipped with.
    static var previousDefaults: [CaptureCommand: [KeyboardShortcuts.Shortcut]] {
        var result: [CaptureCommand: [KeyboardShortcuts.Shortcut]] = [:]
        for table in [versionOneDefaults, versionTwoDefaults] {
            for (command, shortcut) in table {
                result[command, default: []].append(shortcut)
            }
        }
        return result
    }

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }
        var current: [CaptureCommand: KeyboardShortcuts.Shortcut] = [:]
        var newDefaults: [CaptureCommand: KeyboardShortcuts.Shortcut] = [:]
        for command in CaptureCommand.allCases {
            current[command] = KeyboardShortcuts.getShortcut(for: command.shortcutName)
            newDefaults[command] = command.shortcutName.initialShortcut
        }
        for (command, shortcut) in plan(current: current, previous: previousDefaults, newDefaults: newDefaults) {
            KeyboardShortcuts.setShortcut(shortcut, for: command.shortcutName)
        }
        defaults.set(currentVersion, forKey: versionKey)
    }

    /// What to write, as `command → shortcut` (nil clears it). Pure, so it can be tested
    /// without touching the real preferences.
    ///
    /// Clears are resolved before assignments, because new defaults reuse keys old ones
    /// held (⌃⇧5 and ⌃⇧6 were the record commands): checking for a clash against the
    /// pre-migration state would refuse every one of them.
    static func plan(
        current: [CaptureCommand: KeyboardShortcuts.Shortcut],
        previous: [CaptureCommand: [KeyboardShortcuts.Shortcut]],
        newDefaults: [CaptureCommand: KeyboardShortcuts.Shortcut]
    ) -> [(CaptureCommand, KeyboardShortcuts.Shortcut?)] {
        let untouched = CaptureCommand.allCases.filter { command in
            guard let saved = current[command] else { return false }
            return previous[command, default: []].contains(saved) && saved != newDefaults[command]
        }
        var result = current
        for command in untouched {
            result[command] = nil
        }
        var writes: [(CaptureCommand, KeyboardShortcuts.Shortcut?)] = []
        for command in untouched {
            guard let target = newDefaults[command] else {
                writes.append((command, nil))
                continue
            }
            if !result.values.contains(target) {
                result[command] = target
                writes.append((command, target))
            } else if let kept = current[command], !result.values.contains(kept) {
                // The new keys are taken; keeping the old ones beats having none.
                result[command] = kept
            } else {
                writes.append((command, nil))
            }
        }
        return writes
    }
}
