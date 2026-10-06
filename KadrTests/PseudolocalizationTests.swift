import AppKit
import Foundation
import Testing
@testable import Kadr

@Suite("Pseudolocalization")
struct PseudolocalizationTests {
    @Test("The double-length model matches what Foundation renders")
    func doubledMatchesFoundation() {
        // "Cancel Cancel" is what `-NSDoubleLocalizedStrings YES` gives for AppKit's Cancel.
        #expect(Pseudolocalization.doubled("Cancel") == "Cancel Cancel")
    }

    @Test("Kadr reads the system's pseudolanguage defaults, not arguments of its own")
    func systemDefaults() {
        #expect(KadrText.doubleLengthDefault == "NSDoubleLocalizedStrings")
        #expect(KadrText.rightToLeftDefault == "NSForceRightToLeftWritingDirection")
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
