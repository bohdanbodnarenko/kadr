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

    @Test("Plural strings distinguish one from many")
    func plurals() {
        #expect(KadrPlural.captures(1).contains("1"))
        #expect(KadrPlural.files(3).contains("3"))
        #expect(KadrPlural.words(1).contains("1"))
        #expect(KadrPlural.seconds(5).contains("5"))
        #expect(KadrPlural.cards(2).contains("2"))
    }
}
