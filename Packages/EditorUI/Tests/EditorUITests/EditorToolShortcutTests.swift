import AppKit
import Testing
@testable import EditorUI

/// Tool letters by key position (docs/18 ED-6).
@Suite("Editor tool shortcuts")
struct EditorToolShortcutTests {
    @Test("Each tool's key code picks that tool", arguments: EditorTool.allCases)
    func keyCodePicksTool(tool: EditorTool) {
        #expect(EditorTool.tool(forKeyCode: tool.shortcutKeyCode, modifiers: []) == tool)
        #expect(EditorTool.tool(forKeyCode: tool.shortcutKeyCode, modifiers: .shift) == tool)
    }

    @Test("Key codes are unique")
    func uniqueKeyCodes() {
        #expect(Set(EditorTool.allCases.map(\.shortcutKeyCode)).count == EditorTool.allCases.count)
    }

    @Test("A command modifier is never a tool letter", arguments: [
        NSEvent.ModifierFlags.command, .option, .control, [.command, .shift]
    ])
    func modifiersBlockTools(modifiers: NSEvent.ModifierFlags) {
        #expect(EditorTool.tool(forKeyCode: EditorTool.arrow.shortcutKeyCode, modifiers: modifiers) == nil)
    }
}
