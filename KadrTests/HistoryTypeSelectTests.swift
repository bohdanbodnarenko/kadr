import Foundation
import Testing
@testable import Kadr

/// docs/18 OUT-8: typing in History jumps to a name, as in Finder.
@Suite("History type-select")
struct HistoryTypeSelectTests {
    private let ids = (0 ..< 4).map { _ in UUID() }

    private var titles: [(UUID, String)] {
        zip(ids, ["Bug report.png", "Café menu.png", "cafe receipt.png", "2026 roadmap.png"]).map { ($0, $1) }
    }

    @Test("The first title starting with the prefix wins, ignoring case and accents", arguments: [
        ("b", 0),
        ("CAF", 1),
        ("cafe r", 2),
        ("2", 3)
    ])
    func matches(prefix: String, index: Int) {
        #expect(HistorySelection.firstMatch(prefix: prefix, in: titles) == ids[index])
    }

    @Test("A prefix nothing starts with matches nothing, and a middle match does not count")
    func noMatch() {
        #expect(HistorySelection.firstMatch(prefix: "zebra", in: titles) == nil)
        #expect(HistorySelection.firstMatch(prefix: "menu", in: titles) == nil)
    }
}
