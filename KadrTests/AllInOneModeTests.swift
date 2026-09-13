import Testing
@testable import Kadr

@MainActor
@Suite("All-in-One modes")
struct AllInOneModeTests {
    @Test("Every mode has a unique in-HUD shortcut")
    func shortcutsAreUnique() {
        let keys = AllInOneMode.allCases.map(\.shortcut)
        #expect(Set(keys).count == keys.count)
    }

    @Test("Letter keys map onto the modes CleanShot users reach for", arguments: [
        ("a", AllInOneMode.area),
        ("w", AllInOneMode.window),
        ("f", AllInOneMode.screen),
        ("r", AllInOneMode.record),
        ("g", AllInOneMode.gif),
        ("s", AllInOneMode.scrolling),
        ("t", AllInOneMode.ocr),
        ("p", AllInOneMode.color),
        ("A", AllInOneMode.area)
    ])
    func matchingShortcut(pair: (String, AllInOneMode)) {
        #expect(AllInOneMode.matching(shortcut: pair.0) == pair.1)
    }

    @Test("Unknown keys do not pick a mode")
    func unknownShortcut() {
        #expect(AllInOneMode.matching(shortcut: "x") == nil)
        #expect(AllInOneMode.matching(shortcut: "") == nil)
    }
}
