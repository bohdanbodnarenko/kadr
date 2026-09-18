import Testing
@testable import Kadr

/// The recorder's single-key shortcuts (docs/03 §1.4).
///
/// The island could be opened and a mode picked without the mouse, and then the recorder
/// asked for a click to do the one thing it exists for. These are the keys that finish the
/// path — and the rule that the letters mean the same thing they mean on the island.
@Suite("Record setup keys")
struct RecordSetupKeyTests {
    struct Case {
        let name: String
        let characters: String
        let expected: RecordSetupKey?
    }

    @Test("Each letter reaches its own control", arguments: [
        Case(name: "area", characters: "a", expected: .area),
        Case(name: "window", characters: "w", expected: .window),
        Case(name: "full screen", characters: "f", expected: .screen),
        Case(name: "microphone", characters: "m", expected: .microphone),
        Case(name: "system audio", characters: "s", expected: .systemAudio),
        Case(name: "camera", characters: "c", expected: .camera),
        Case(name: "click highlights", characters: "h", expected: .clicks),
        Case(name: "keystrokes", characters: "k", expected: .keystrokes),
        Case(name: "teleprompter", characters: "t", expected: .teleprompter),
        Case(name: "record", characters: "r", expected: .record),
        Case(name: "capitals are the same key", characters: "A", expected: .area),
        Case(name: "an unbound letter is left alone", characters: "q", expected: nil),
        Case(name: "nothing typed is nothing pressed", characters: "", expected: nil)
    ])
    func letters(_ testCase: Case) {
        #expect(RecordSetupKey.match(testCase.characters) == testCase.expected, "\(testCase.name)")
    }

    @Test("Return records and Escape steps back")
    func returnAndEscape() {
        #expect(RecordSetupKey.match("", isReturn: true) == .record)
        #expect(RecordSetupKey.match("", isEscape: true) == .back)
        // Escape wins: it is the way out, and a way out that depends on what else is true
        // is not a way out.
        #expect(RecordSetupKey.match("a", isReturn: true, isEscape: true) == .back)
    }

    /// A key that means one thing on the island must not mean another here.
    @Test("The letters agree with the island's")
    func agreesWithTheIsland() {
        #expect(RecordSetupKey.match(String(AllInOneMode.area.shortcut)) == .area)
        #expect(RecordSetupKey.match(String(AllInOneMode.window.shortcut)) == .window)
        #expect(RecordSetupKey.match(String(AllInOneMode.screen.shortcut)) == .screen)
    }

    @Test("No key does two jobs")
    func lettersAreDistinct() {
        let letters = "awfmschktr".map(String.init)
        let matched = letters.compactMap { RecordSetupKey.match($0) }

        #expect(matched.count == letters.count)
        #expect(Set(matched.map(\.caption)).count == letters.count)
    }

    @Test("Every key says what it is")
    func captionsExist() {
        let keys: [RecordSetupKey] = [
            .area, .window, .screen, .microphone, .systemAudio,
            .camera, .clicks, .keystrokes, .teleprompter, .record, .back
        ]
        #expect(keys.allSatisfy { !$0.caption.isEmpty })
        #expect(RecordSetupKey.record.caption == "return")
        #expect(RecordSetupKey.back.caption == "esc")
    }
}
