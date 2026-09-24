import Foundation
import Testing
@testable import Shared

/// What OCR actually hands the scanner (docs/17 T-REL-8).
///
/// Each input is a real misreading seen from Vision on macOS 27 or a lookalike of one:
/// trailing glyphs on a line, `l`/`I`/`|` for 1, `O` for 0, a space inside a long token.
/// An auto-redaction that silently misses a card number is a privacy defect, not a
/// flaky test, so these are asserted rather than tolerated.
@Suite("Secret scanner under OCR noise")
struct SecretScannerOCRNoiseTests {
    @Test("Noisy secrets are still found", arguments: [
        (SecretKind.creditCard, "5500000000000004ÍšÍš", "5500000000000004"),
        (.creditCard, "4111 l111 1111 1111", "4111111111111111"),
        (.creditCard, "4111-1111-1111-111|", "4111111111111111"),
        (.creditCard, "card 4111111111111111. thanks", "4111111111111111"),
        (.creditCard, "55OO 0000 0000 0004", "5500000000000004"),
        (.apiKey, "sk_live_51 FakeTestKeyWithHighEntropyXX", "sk_live_51FakeTestKeyWithHighEntropyXX"),
        (.jwt, "eyJhbGciOiJIUz|1 NilsInR5cC|6|kpXVCJ9.eyJzdWIiOilxMjMOIn0.Sf|KxwRJSMeKKF2QT4fwpMeJf36POk6yJV", "eyJ")
    ])
    func noisySecretsAreFound(kind: SecretKind, text: String, expected: String) {
        let found = SecretScanner.matches(in: text)
        #expect(
            found.contains { $0.kind == kind && $0.text.contains(expected) },
            "missed \(kind.rawValue) in \(text): \(found)"
        )
    }

    @Test("A found card's range covers the noisy characters, not just the digits")
    func rangeCoversTheGlyphs() throws {
        let text = "Pay 4111 l111 1111 1111 now"
        let card = try #require(SecretScanner.matches(in: text).first { $0.kind == .creditCard })
        let covered = (text as NSString).substring(with: card.nsRange)
        #expect(covered == "4111 l111 1111 1111")
    }

    @Test("Words next to numbers are not read as digits", arguments: [
        "prefix 4111111111111111 suffix",
        "Order 1234567890 Shipped",
        "Soon 12 Oct 2026"
    ])
    func wordsStayWords(text: String) {
        let digitized = SecretScanner.digitized(text)
        let letters = { (value: String) in value.filter(\.isLetter) }
        #expect(letters(digitized) == letters(text))
    }

    @Test("Lookalikes that do not make a valid card are not a card")
    func luhnStillGuards() {
        #expect(!SecretScanner.matches(in: "4111 l111 1111 1112").contains { $0.kind == .creditCard })
    }
}
