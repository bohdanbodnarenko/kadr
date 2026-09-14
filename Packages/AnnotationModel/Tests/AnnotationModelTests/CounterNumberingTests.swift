import Foundation
import Testing
@testable import AnnotationModel

@Suite("Counter numbering")
struct CounterNumberingTests {
    @Test("Arabic is the number itself")
    func arabic() {
        #expect(CounterNumbering.arabic.label(for: 1) == "1")
        #expect(CounterNumbering.arabic.label(for: 12) == "12")
    }

    @Test("Roman uses subtractive notation", arguments: [
        (1, "I"),
        (4, "IV"),
        (9, "IX"),
        (12, "XII"),
        (40, "XL")
    ])
    func roman(pair: (Int, String)) {
        #expect(CounterNumbering.roman.label(for: pair.0) == pair.1)
    }

    @Test("Latin letters wrap past Z", arguments: [
        (1, "A"),
        (26, "Z"),
        (27, "AA")
    ])
    func latinUpper(pair: (Int, String)) {
        #expect(CounterNumbering.latinUpper.label(for: pair.0) == pair.1)
    }

    @Test("Latin lowercase wraps past z", arguments: [
        (1, "a"),
        (26, "z"),
        (27, "aa")
    ])
    func latinLower(pair: (Int, String)) {
        #expect(CounterNumbering.latinLower.label(for: pair.0) == pair.1)
    }

    @Test("A missing numbering on an old document is arabic")
    func defaultNumbering() {
        let spec = CounterSpec(center: .zero)
        #expect(spec.numberingStyle == .arabic)
        #expect(spec.label == "1")
    }
}
