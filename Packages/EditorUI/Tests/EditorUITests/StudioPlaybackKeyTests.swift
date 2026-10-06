import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import EditorUI

/// The studio's bare playback keys (docs/09 U3.3).
///
/// They used to be declared as SwiftUI `keyboardShortcut`s on an invisible zero-size button
/// so that they would survive the transport bar's three layouts. They did not survive it —
/// nothing honoured them — and a bare key equivalent would have fired while the user was
/// typing anyway. This is the table the responder chain consults instead.
@Suite("Studio playback keys")
struct StudioPlaybackKeyTests {
    struct Case {
        let name: String
        let keyCode: Int
        let modifiers: NSEvent.ModifierFlags
        let expected: StudioPlaybackKey?
    }

    @Test("Every key means what the transport bar says it means", arguments: [
        Case(name: "space plays", keyCode: kVK_Space, modifiers: [], expected: .togglePlayback),
        Case(name: "left steps back", keyCode: kVK_LeftArrow, modifiers: [], expected: .step(frames: -1)),
        Case(name: "right steps on", keyCode: kVK_RightArrow, modifiers: [], expected: .step(frames: 1)),
        Case(
            name: "option-left skips back",
            keyCode: kVK_LeftArrow,
            modifiers: .option,
            expected: .skip(seconds: -5)
        ),
        Case(
            name: "option-right skips on",
            keyCode: kVK_RightArrow,
            modifiers: .option,
            expected: .skip(seconds: 5)
        ),
        // Arrow keys arrive carrying .function and .numericPad; neither is the user's doing.
        Case(
            name: "the arrows' own flags are not modifiers",
            keyCode: kVK_RightArrow,
            modifiers: [.function, .numericPad],
            expected: .step(frames: 1)
        ),
        // Left alone: the menus own ⌘ and ⌃, and the focused timeline owns ⇧-arrow.
        Case(name: "command-left is the menu's", keyCode: kVK_LeftArrow, modifiers: .command, expected: nil),
        Case(name: "control-space is the system's", keyCode: kVK_Space, modifiers: .control, expected: nil),
        Case(name: "shift-left is the timeline's", keyCode: kVK_LeftArrow, modifiers: .shift, expected: nil),
        Case(name: "option-space is nobody's", keyCode: kVK_Space, modifiers: .option, expected: nil),
        Case(name: "J shuttles back", keyCode: kVK_ANSI_J, modifiers: [], expected: .shuttleReverse),
        Case(name: "K stops", keyCode: kVK_ANSI_K, modifiers: [], expected: .shuttleStop),
        Case(name: "L shuttles on", keyCode: kVK_ANSI_L, modifiers: [], expected: .shuttleForward),
        Case(name: "Home goes to the start", keyCode: kVK_Home, modifiers: [.function], expected: .seekToStart),
        Case(name: "End goes to the end", keyCode: kVK_End, modifiers: [.function], expected: .seekToEnd),
        Case(name: "I marks in", keyCode: kVK_ANSI_I, modifiers: [], expected: .markIn),
        Case(name: "O marks out", keyCode: kVK_ANSI_O, modifiers: [], expected: .markOut),
        Case(name: "option-X clears the marks", keyCode: kVK_ANSI_X, modifiers: .option, expected: .clearMarks),
        Case(name: "a bare X is not a mark key", keyCode: kVK_ANSI_X, modifiers: [], expected: nil),
        Case(name: "command-L is the menu's", keyCode: kVK_ANSI_L, modifiers: .command, expected: nil),
        Case(name: "an unrelated key falls through", keyCode: kVK_ANSI_Q, modifiers: [], expected: nil)
    ])
    func matches(_ testCase: Case) {
        #expect(
            StudioPlaybackKey.match(keyCode: testCase.keyCode, modifiers: testCase.modifiers)
                == testCase.expected,
            "\(testCase.name)"
        )
    }
}
