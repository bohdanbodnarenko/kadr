import CoreGraphics
import Foundation
import Testing
@testable import Shared

/// Ten secrets covering every built-in detector (docs/06 M18).
///
/// These are well-known test vectors, not live credentials: Visa's `4111…` PAN, AWS's
/// documented example access key, and a truncated JWT whose signature is filler.
enum SeededSecrets {
    static let all: [(kind: SecretKind, text: String)] = [
        (.email, "user@example.com"),
        (.email, "first.last@company.co.uk"),
        (.phone, "+1 (415) 555-2671"),
        (.phone, "020 7946 0958"),
        (.creditCard, "4111111111111111"),
        (.creditCard, "5500000000000004"),
        (.iban, "DE89370400440532013000"),
        (.jwt, "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0In0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV"),
        (.apiKey, "sk_live_51FakeTestKeyWithHighEntropyXX"),
        (.apiKey, "AKIAIOSFODNN7EXAMPLE")
    ]

    static var joined: String {
        all.map(\.text).joined(separator: "\n")
    }
}

@Suite("Secret scanner")
struct SecretScannerTests {
    @Test("The seeded ten secrets are all proposed at review, none skipped")
    func seededSecretsAreAllFound() {
        let found = SecretScanner.matches(in: SeededSecrets.joined)
        #expect(found.count >= SeededSecrets.all.count)

        for secret in SeededSecrets.all {
            let hit = found.first { candidate in
                candidate.kind == secret.kind && Self.looselyContains(candidate.text, secret.text)
            }
            #expect(hit != nil, "missed \(secret.kind.rawValue) \(secret.text)")
        }
    }

    @Test("Each detector has a documented regex and a positive match", arguments: SeededSecrets.all)
    func eachDetectorHits(secret: (kind: SecretKind, text: String)) {
        let found = SecretScanner.matches(in: "prefix \(secret.text) suffix")
        #expect(found.contains { $0.kind == secret.kind && Self.looselyContains($0.text, secret.text) })
    }

    @Test("A Luhn failure is not a card")
    func invalidLuhnIsRejected() {
        // Same length as the Visa test PAN, last digit off so the checksum fails.
        let found = SecretScanner.matches(in: "4111111111111112")
        #expect(!found.contains { $0.kind == .creditCard })
    }

    @Test("An IBAN with a broken checksum is rejected")
    func invalidIBANIsRejected() {
        let found = SecretScanner.matches(in: "DE00370400440532013000")
        #expect(!found.contains { $0.kind == .iban })
    }

    @Test("Not every @-sign is an email")
    func localPartWithoutTLDIsRejected() {
        let found = SecretScanner.matches(in: "send to root@localhost now")
        #expect(!found.contains { $0.kind == .email })
    }

    @Test("A two-segment token is not a JWT")
    func incompleteJWTIsRejected() {
        let found = SecretScanner.matches(in: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0In0")
        #expect(!found.contains { $0.kind == .jwt })
    }

    @Test("A JWT garbled by OCR is still proposed for review")
    func ocrSubstitutionsStillMatchJWT() {
        // Capital I read as l, Latin K/e/P as Cyrillic — typical of a screenshot.
        let garbled = "eyJhbGciOiJIUzI1NiIslnR5cCI6IkрХVCJ9.eyJzdWliOilxMjMOIn0.SflKxwRJSМеKKF2QT4fwpМeJf36РOk6yJV"
        let found = SecretScanner.matches(in: garbled)
        #expect(found.contains { $0.kind == .jwt })
    }

    @Test("English words are not API keys even when long")
    func lowEntropyIsRejected() {
        let found = SecretScanner.matches(in: "thequickbrownfoxjumpsoverthelazydog")
        #expect(!found.contains { $0.kind == .apiKey })
    }

    @Test("A 40-character hex digest is not an API key")
    func gitSHAIsRejected() {
        let sha = String(repeating: "abcdef0123", count: 4)
        #expect(sha.count == 40)
        let found = SecretScanner.matches(in: sha)
        #expect(!found.contains { $0.kind == .apiKey })
    }

    @Test("Luhn accepts the Visa and Mastercard test PANs")
    func luhnKnownCards() {
        #expect(SecretScanner.luhnIsValid("4111111111111111"))
        #expect(SecretScanner.luhnIsValid("5500000000000004"))
        #expect(!SecretScanner.luhnIsValid("4111111111111112"))
        #expect(!SecretScanner.luhnIsValid("123"))
    }

    @Test("IBAN mod-97 accepts the Wikipedia German example")
    func ibanWikipediaExample() {
        #expect(SecretScanner.ibanChecksumIsValid("DE89370400440532013000"))
        #expect(!SecretScanner.ibanChecksumIsValid("DE00370400440532013000"))
    }

    @Test("Cards printed with dashes still match")
    func dashedCard() {
        let found = SecretScanner.matches(in: "Visa 4111-1111-1111-1111")
        #expect(found.contains { $0.kind == .creditCard && $0.text == "4111111111111111" })
    }

    @Test("IBANs printed in groups of four still match")
    func groupedIBAN() {
        let found = SecretScanner.matches(in: "DE89 3704 0044 0532 0130 00")
        #expect(found.contains { $0.kind == .iban && $0.text == "DE89370400440532013000" })
    }

    @Test("A card is not also reported as a phone")
    func cardIsNotAPhone() {
        let found = SecretScanner.matches(in: "4111111111111111")
        #expect(found.filter { $0.kind == .creditCard }.count == 1)
        #expect(!found.contains { $0.kind == .phone })
    }

    @Test("The find field is case-insensitive and ignores one-character queries")
    func findField() {
        let text = "Error: stripe checkout failed"
        #expect(SecretScanner.matches(query: "s", in: text).isEmpty)
        let hits = SecretScanner.matches(query: "STRIPE", in: text)
        #expect(hits.count == 1)
        #expect(hits[0].kind == .custom)
        #expect(hits[0].text.lowercased() == "stripe")
    }

    @Test("Vision boxes flip from bottom-left to top-left")
    func visionBoxFlip() {
        let vision = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let topLeft = VisionNormalizedBox.topLeft(fromVision: vision)
        #expect(abs(topLeft.minX - 0.1) < 0.0001)
        #expect(abs(topLeft.minY - 0.4) < 0.0001)
        #expect(abs(topLeft.width - 0.3) < 0.0001)
        #expect(abs(topLeft.height - 0.4) < 0.0001)
    }

    @Test("A candidate rect is padded and stays inside the image")
    func candidateRectClamp() {
        let candidate = RedactionCandidate(
            kind: .email,
            text: "a@b.co",
            boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        )
        let rect = candidate.rect(in: CGSize(width: 100, height: 100), padding: 3)
        #expect(rect.minX == 0)
        #expect(rect.minY == 0)
        #expect(rect.width == 13)
        #expect(rect.height == 13)
    }

    @Test("Analysis JSON without candidates still decodes")
    func analysisDecodesWithoutCandidates() throws {
        let json = Data(#"{"lines":[],"codes":[]}"#.utf8)
        let analysis = try JSONDecoder().decode(VisionAnalysis.self, from: json)
        #expect(analysis.candidates.isEmpty)
    }

    private static func looselyContains(_ haystack: String, _ needle: String) -> Bool {
        let foldedHay = haystack.filter { !$0.isWhitespace && $0 != "-" }
        let foldedNeedle = needle.filter { !$0.isWhitespace && $0 != "-" }
        return haystack.localizedCaseInsensitiveContains(needle)
            || foldedHay.localizedCaseInsensitiveContains(foldedNeedle)
    }
}
