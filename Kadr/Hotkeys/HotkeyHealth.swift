import AppKit
import Carbon
import Foundation
import KeyboardShortcuts
import os
import Shared

/// Probes whether a shortcut can be registered, without stealing Kadr's own hotkey
/// (docs/16 X-2). Event-driven: no timers.
@MainActor
@Observable
final class HotkeyHealth {
    private(set) var conflicts: [CaptureCommand: String] = [:]
    private let logger = KadrLog.logger(.hotkeys)

    /// Call *before* KeyboardShortcuts registers, otherwise Carbon reports Kadr itself.
    func probeAll() {
        var next: [CaptureCommand: String] = [:]
        for command in CaptureCommand.allCases {
            guard let shortcut = KeyboardShortcuts.getShortcut(for: command.shortcutName) else {
                continue
            }
            if let reason = Self.carbonConflict(shortcut) {
                next[command] = reason
                logger.info(
                    "Shortcut for \(command.rawValue, privacy: .public) is taken: \(reason, privacy: .public)"
                )
            }
        }
        conflicts = next
    }

    var hasConflicts: Bool {
        !conflicts.isEmpty
    }

    func message(for command: CaptureCommand) -> String? {
        conflicts[command]
    }

    nonisolated static func carbonConflict(_ shortcut: KeyboardShortcuts.Shortcut) -> String? {
        let hotKeyID = EventHotKeyID(signature: 0x4B44_5248, id: 1)
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.carbonKeyCode),
            UInt32(shortcut.carbonModifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        guard status != noErr else { return nil }
        return "May be used by another app"
    }
}
