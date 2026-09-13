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

    @Test("Device-dependent flags on the event do not defeat the check")
    func devicePrivateFlagsAreIgnored() {
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

    @Test("Every command ships a default shortcut, and none collide")
    func initialShortcutsAreDistinct() {
        let defaults = CaptureCommand.allCases.compactMap(\.shortcutName.initialShortcut)
        #expect(defaults.count == CaptureCommand.allCases.count)
        #expect(Set(defaults).count == defaults.count)
    }

    @Test("The menu lists the capture actions from docs/03 §8.1")
    func menuCommands() {
        #expect(CaptureCommand.menuCommands == [
            .allInOne,
            .captureArea,
            .captureWindow,
            .captureFullscreen,
            .captureScrolling,
            .captureText,
            .pickColor
        ])
        #expect(CaptureCommand.menuCommands.allSatisfy { !$0.title.isEmpty })
        // Repeating the last region is a hotkey, not a menu item (docs/03 §8.1).
        #expect(!CaptureCommand.menuCommands.contains(.capturePreviousArea))
        #expect(!CaptureCommand.menuCommands.contains(.captureAreaAndCopy))
    }

    @Test("Utility commands include the self-timer")
    func utilityCommandsIncludeSelfTimer() {
        #expect(CaptureCommand.utilityCommands.contains(.selfTimer))
        #expect(CaptureCommand.utilityCommands.contains(.freezeScreen))
    }

    @Test("Overlay commands cover close, save and hide")
    func overlayCommands() {
        #expect(CaptureCommand.overlayCommands == [
            .saveAllOverlays,
            .closeAllOverlays,
            .hideOverlays
        ])
    }
}
