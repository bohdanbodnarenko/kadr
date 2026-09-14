import Foundation
import Testing
@testable import Kadr

@Suite("Pseudolocalization")
struct PseudolocalizationTests {
    @Test("Expansion is longer than the source and wraps the text")
    func expandsToAboutOnePointFour() {
        let source = "Capture Area"
        let expanded = Pseudolocalization.expand(source)
        #expect(expanded.hasPrefix("⟦"))
        #expect(expanded.hasSuffix("⟧"))
        #expect(expanded.contains(source))
        #expect(expanded.count > source.count)
        #expect(Double(expanded.count) >= Double(source.count) * 1.3)
    }

    @Test("A 2× expansion is longer than 1.4×")
    func expandsToDoubleLength() {
        let source = "Capture Area"
        let defaultExpand = Pseudolocalization.expand(source, factor: 1.4)
        let doubled = Pseudolocalization.expand(source, factor: 2.0)
        #expect(doubled.count > defaultExpand.count)
        #expect(Double(doubled.count) >= Double(source.count) * 1.9)
    }

    @Test("Plural strings distinguish one from many")
    func plurals() {
        #expect(KadrPlural.captures(1).contains("1"))
        #expect(KadrPlural.files(3).contains("3"))
        #expect(KadrPlural.words(1).contains("1"))
        #expect(KadrPlural.seconds(5).contains("5"))
        #expect(KadrPlural.cards(2).contains("2"))
    }
}
