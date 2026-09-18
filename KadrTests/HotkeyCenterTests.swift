import AppKit
import KeyboardShortcuts
import Testing
@testable import Kadr

@MainActor
@Suite("Hotkey validation")
struct HotkeyValidationTests {
    /// Every case uses the same key; only the modifiers matter to the rule.
    private func validate(_ modifiers: NSEvent.ModifierFlags) -> KeyboardShortcuts.ValidationResult {
        HotkeyCenter.validate(KeyboardShortcuts.Shortcut(.a, modifiers: modifiers))
    }

    @Test("Option on its own is refused (docs/04 §3.2 — broken on macOS 15)")
    func optionOnlyIsRefused() {
        guard case .disallow = validate([.option]) else {
            Issue.record("⌥A should have been refused")
            return
        }
    }

    @Test("Option combined with another modifier is fine", arguments: [
        NSEvent.ModifierFlags([.option, .command]),
        NSEvent.ModifierFlags([.option, .control]),
        NSEvent.ModifierFlags([.option, .shift]),
        NSEvent.ModifierFlags([.option, .command, .shift])
    ])
    func optionWithOtherModifiersIsAllowed(modifiers: NSEvent.ModifierFlags) {
        #expect(validate(modifiers) == .allow)
    }

    @Test("Shortcuts without Option are untouched", arguments: [
        NSEvent.ModifierFlags([.control, .shift]),
        NSEvent.ModifierFlags([.command]),
        NSEvent.ModifierFlags([.command, .shift])
    ])
    func otherShortcutsAreAllowed(modifiers: NSEvent.ModifierFlags) {
        #expect(validate(modifiers) == .allow)
    }

    @Test("A shortcut already used by another command is refused")
    func duplicateShortcutIsRefused() {
        let shortcut = KeyboardShortcuts.Shortcut(.a, modifiers: [.control, .shift])
        let others: [CaptureCommand: KeyboardShortcuts.Shortcut] = [
            .captureArea: shortcut
        ]
        guard case let .disallow(reason) = HotkeyCenter.validate(
            shortcut,
            for: .captureWindow,
            others: others
        ) else {
            Issue.record("A duplicate shortcut should have been refused")
            return
        }
        #expect(reason.contains("Capture Area"))
    }

    @Test("Device-dependent flags do not hide a lone Option")
    func optionWithDeviceFlagsIsRefused() {
        // Real NSEvents carry flags like the numeric-pad and function bits; the rule
        // must look only at the modifier keys the user actually held.
        let modifiers: NSEvent.ModifierFlags = [.option, .numericPad]
        guard case .disallow = validate(modifiers) else {
            Issue.record("⌥A with a device-dependent flag should still be refused")
            return
        }
    }
}

@MainActor
@Suite("Capture commands")
struct CaptureCommandTests {
    @Test("Every command has a distinct shortcut name")
    func shortcutNamesAreDistinct() {
        let names = CaptureCommand.allCases.map(\.shortcutName.rawValue)
        #expect(Set(names).count == CaptureCommand.allCases.count)
        #expect(names == CaptureCommand.allCases.map(\.rawValue))
    }

    @Test("Only the five everyday commands ship a default, and none collide")
    func initialShortcutsAreFewAndDistinct() {
        let shipped = CaptureCommand.allCases.filter { $0.shortcutName.initialShortcut != nil }
        #expect(Set(shipped) == [.allInOne, .captureArea, .captureFullscreen, .recordSetup, .stopRecording])
        let defaults = shipped.compactMap(\.shortcutName.initialShortcut)
        #expect(Set(defaults).count == defaults.count)
    }

    @Test("Direct captures mirror the system's numbers with Control-Shift", arguments: [
        (CaptureCommand.captureFullscreen, KeyboardShortcuts.Key.three),
        (.captureArea, .four),
        (.recordSetup, .six),
        (.stopRecording, .period)
    ])
    func defaultsUseControlShift(command: CaptureCommand, key: KeyboardShortcuts.Key) {
        #expect(command.shortcutName.initialShortcut == .init(key, modifiers: [.control, .shift]))
    }

    @Test("The capture island sits beside the system's screenshot keys, on Shift-Command-2")
    func islandShortcut() {
        #expect(CaptureCommand.allInOne.shortcutName.initialShortcut == .init(.two, modifiers: [.command, .shift]))
    }

    @Test("Settings lists every command exactly once")
    func shortcutSectionsCoverEveryCommand() {
        let listed = CaptureCommand.shortcutSections.flatMap(\.commands)
        #expect(listed.count == CaptureCommand.allCases.count)
        #expect(Set(listed) == Set(CaptureCommand.allCases))
        #expect(CaptureCommand.shortcutSections.allSatisfy { !$0.title.isEmpty && !$0.commands.isEmpty })
        #expect(listed.allSatisfy { !$0.title.isEmpty })
    }
}
