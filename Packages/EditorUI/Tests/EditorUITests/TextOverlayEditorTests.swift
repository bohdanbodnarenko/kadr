import AnnotationModel
import AppKit
import Testing
@testable import EditorUI

@MainActor
@Suite("Text overlay keys (T-ED-4)")
struct TextOverlayEditorTests {
    @Test(
        "Which keys commit a caption",
        arguments: [
            (UInt16(36), NSEvent.ModifierFlags.command, true), // ⌘Return
            (UInt16(36), NSEvent.ModifierFlags(), false), // Return is a newline
            (UInt16(36), NSEvent.ModifierFlags.shift, false),
            (UInt16(36), NSEvent.ModifierFlags([.command, .shift]), false),
            (UInt16(76), NSEvent.ModifierFlags(), true), // keypad Enter
            (UInt16(76), NSEvent.ModifierFlags.option, false),
            (UInt16(0), NSEvent.ModifierFlags.command, false) // ⌘A
        ]
    )
    func commitKeys(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, commits: Bool) {
        // Device-dependent flags such as caps lock and the function key never matter.
        let noisy = modifiers.union([.capsLock, .numericPad])
        #expect(CommittingTextView.isCommitKey(keyCode: keyCode, modifiers: noisy) == commits)
    }

    @Test("Escape commits what was typed instead of throwing it away")
    func escapeCommits() {
        let editor = TextOverlayEditor()
        var changes: [String] = []
        var finished: [AnnotationID] = []
        editor.onChange = { _, string in changes.append(string) }
        editor.onFinish = { finished.append($0) }

        var spec = TextSpec(rect: CGRect(x: 0, y: 0, width: 200, height: 40))
        spec.string = ""
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        editor.begin(editing: spec, in: container)
        let field = container.subviews.compactMap { $0 as? CommittingTextView }.first
        #expect(field != nil)
        field?.string = "Typed caption"
        editor.textDidChange(Notification(name: NSText.didChangeNotification))

        let handled = field.map {
            editor.textView($0, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        #expect(handled == true)
        #expect(!editor.isEditing)
        #expect(finished == [spec.id])
        #expect(changes == ["Typed caption"])
    }

    @Test("⌘Return on the field commits")
    func commandReturnCommits() throws {
        let editor = TextOverlayEditor()
        var finished = 0
        editor.onFinish = { _ in finished += 1 }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        editor.begin(editing: TextSpec(rect: CGRect(x: 0, y: 0, width: 200, height: 40)), in: container)
        let field = try #require(container.subviews.compactMap { $0 as? CommittingTextView }.first)

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: CommittingTextView.returnKeyCode
        ))
        field.keyDown(with: event)
        #expect(finished == 1)
        #expect(!editor.isEditing)
    }
}
