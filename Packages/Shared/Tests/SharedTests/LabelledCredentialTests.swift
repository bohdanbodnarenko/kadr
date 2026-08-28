import Foundation
import Testing
@testable import Shared

/// Smart redaction 2.0 (docs/03 §3, docs/08 §2.4, docs/09 U1.6).
///
/// The detector that no amount of pattern matching replaces: `hunter2` is an ordinary
/// string, and the only thing that marks it as a password is the word in front of it.
/// Everything else here recognises a *value*; this recognises a *label*.
@Suite("Labelled credentials")
struct LabelledCredentialTests {
    private func credentials(in text: String) -> [SecretMatch] {
        SecretScanner.matches(in: text).filter { $0.kind == .credential }
    }

    /// The whole point: only the value is proposed for redaction, never the label.
    /// Redacting the line would hide *which* field was censored, and a reviewer accepting
    /// a candidate needs to see that it was the password rather than the username.
    @Test("Only the value is redacted, not the label", arguments: [
        ("password: hunter2", "hunter2"),
        ("Password : hunter2", "hunter2"),
        ("token=abc123def", "abc123def"),
        ("api_key = swordfish99", "swordfish99"),
        ("API Key: swordfish99", "swordfish99"),
        ("client_secret=s3cr3tv4lue", "s3cr3tv4lue"),
        ("PIN: 4821", "4821"),
        ("passphrase: correct-horse", "correct-horse")
    ])
    func valueOnly(line: String, expected: String) throws {
        let found = credentials(in: line)
        let match = try #require(found.first, "nothing found in \(line)")
        #expect(match.text == expected)
        // And the proposed span starts after the label.
        #expect(match.location >= line.count - expected.count)
    }

    @Test("A quoted value may contain spaces")
    func quotedValue() throws {
        let match = try #require(credentials(in: #"password: "correct horse battery""#).first)
        #expect(match.text == "correct horse battery")
    }

    @Test("A bearer token is caught without a colon in front of it")
    func bearerToken() throws {
        let header = "Authorization: Bearer abc123def456ghi789"
        let match = try #require(credentials(in: header).first)
        #expect(match.text == "abc123def456ghi789")
    }

    /// A weak password is exactly what no other detector can see.
    @Test("A weak password is caught, though nothing about it looks secret")
    func weakPassword() {
        #expect(SecretScanner.matches(in: "hunter2").isEmpty, "on its own it is just a word")
        #expect(!credentials(in: "password: hunter2").isEmpty, "labelled, it is a secret")
    }

    @Test("The value stops at the end of the line")
    func valueStopsAtTheLine() throws {
        let blob = "password: hunter2\nusername: alice"
        let match = try #require(credentials(in: blob).first)
        #expect(match.text == "hunter2")
    }

    /// An already-masked field is noise in the review strip, and noise is what makes a
    /// review step get skipped.
    @Test("An already-masked value is not proposed", arguments: [
        "password: ••••••",
        "password: ********",
        "pin: ----",
        "token: ......"
    ])
    func placeholdersAreIgnored(line: String) {
        #expect(credentials(in: line).isEmpty)
    }

    @Test("A label with nothing after it proposes nothing", arguments: [
        "password:",
        "token = ",
        "api_key:  ",
        "pin: 1"
    ])
    func emptyValuesAreIgnored(line: String) {
        #expect(credentials(in: line).isEmpty)
    }

    @Test("An ordinary sentence containing the word is not a credential", arguments: [
        "Reset your password on the settings page.",
        "The token is stored securely.",
        "Choose a strong passphrase."
    ])
    func proseIsNotACredential(line: String) {
        #expect(credentials(in: line).isEmpty)
    }

    @Test("Several credentials on several lines are all found")
    func severalCredentials() {
        let blob = """
        username: alice
        password: hunter2
        api_key = sk_live_abcdefghijklmnop
        token: t0k3nv4lu3
        """
        #expect(SecretScanner.matches(in: blob).count >= 3)
    }
}

/// The acceptance fixture docs/09 U1.6 asks for: the ten seeded secrets from M18, plus ten
/// new cases including JWTs, `token=` values, and cards that fail Luhn as negatives.
@Suite("Redaction acceptance fixture")
struct RedactionAcceptanceTests {
    /// A screenshot's worth of text with exactly ten secrets in it.
    private let seeded = """
    Contact: alice.smith@example.com
    Phone: +1 (415) 555-2671
    Card: 4111 1111 1111 1111
    IBAN: GB82 WEST 1234 5698 7654 32
    Session: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk
    AWS: AKIAIOSFODNN7EXAMPLE
    Stripe: sk_live_abcdefghijklmnop1234
    GitHub: ghp_abcdefghijklmnopqrstuvwxyz0123
    Google: AIzaSyDaGmWKa4JsXZHjjjjjjjjjjjjjjjjjjjj
    Slack: xoxb-123456789012-abcdefghijkl
    """

    @Test("Every seeded secret is found")
    func seededSecretsAreFound() {
        let found = SecretScanner.matches(in: seeded)
        let kinds = Set(found.map(\.kind))

        #expect(kinds.contains(.email))
        #expect(kinds.contains(.phone))
        #expect(kinds.contains(.creditCard))
        #expect(kinds.contains(.iban))
        #expect(kinds.contains(.jwt))
        #expect(kinds.contains(.apiKey))
        #expect(found.count >= 10, "found \(found.count) of ten seeded secrets")
    }

    @Test("Nothing is proposed over ordinary prose")
    func proseIsClean() {
        let prose = """
        Kadr is a free screen capture app for macOS. It captures a region, a window
        or a whole display, and everything stays on your machine. Version 1.2 was
        released on 3 March and the changelog is on the website.
        """
        #expect(SecretScanner.matches(in: prose).isEmpty, "found \(SecretScanner.matches(in: prose))")
    }

    // MARK: - The ten new cases

    @Test("New positives are all caught", arguments: [
        // A JWT with a longer payload than the seeded one.
        "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJuYW1lIjoiQWxpY2UiLCJyb2xlIjoiYWRtaW4ifQ.QWxpY2VJc0FuQWRtaW4",
        "token=ghs_abcdefghijklmnopqrstuvwxyz0123",
        "password: correcthorsebattery",
        "client_secret = zXy987AbC654dEf321",
        "Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
        // Cards that do pass Luhn, in three common print styles.
        "5500-0000-0000-0004",
        "3400 0000 0000 009",
        "6011000000000004",
        "de89 3704 0044 0532 0130 00",
        "user.name+tag@sub.domain.co.uk"
    ])
    func newPositives(text: String) {
        #expect(!SecretScanner.matches(in: text).isEmpty, "nothing found in \(text)")
    }

    /// The negatives matter more than the positives: a detector that fires on version
    /// numbers and order ids trains the user to dismiss the review strip without reading.
    @Test("New negatives are all ignored", arguments: [
        // Fails Luhn: a plausible-looking sixteen digits that is not a card.
        "4111 1111 1111 1112",
        "1234 5678 9012 3456",
        // A git SHA is not a key.
        "9f2a4c1e8b7d6a5f4e3c2b1a0987654321fedcba",
        // A UUID is an identifier.
        "550e8400-e29b-41d4-a716-446655440000",
        // Version numbers and dates.
        "Version 12.4.1 build 20240317",
        // An IBAN with a broken checksum.
        "GB82 WEST 1234 5698 7654 33",
        // A masked field.
        "password: ********",
        // Prose that mentions a label.
        "Please enter your password on the next screen.",
        // A plain word, however long.
        "internationalisation",
        // A file path.
        "/Users/alice/Library/Application Support/Kadr/history.sqlite"
    ])
    func newNegatives(text: String) {
        #expect(SecretScanner.matches(in: text).isEmpty, "found \(SecretScanner.matches(in: text)) in \(text)")
    }

    // MARK: - Overlap handling

    /// Two detectors finding overlapping halves of one secret must not redact one half and
    /// leave the other visible — the worst possible outcome for a security feature.
    @Test("Same-kind overlaps merge into one span")
    func sameKindOverlapsMerge() {
        let text = "password: sk_live_abcdefghijklmnop1234"
        let found = SecretScanner.matches(in: text)
        // The API-key detector and the credential detector both see this value.
        let covering = found.filter { $0.location + $0.length >= text.count }
        #expect(covering.count == 1, "one box over the value, not two overlapping ones")
    }

    @Test("Different kinds side by side stay separate")
    func differentKindsStaySeparate() {
        let found = SecretScanner.matches(in: "alice@example.com +1 (415) 555-2671")
        #expect(Set(found.map(\.kind)) == [.email, .phone])
    }

    @Test("No two proposed spans overlap")
    func spansNeverOverlap() {
        let found = SecretScanner.matches(in: seeded)
        for (index, match) in found.enumerated() {
            for other in found[(index + 1)...] {
                #expect(
                    NSIntersectionRange(match.nsRange, other.nsRange).length == 0,
                    "\(match) overlaps \(other)"
                )
            }
        }
    }
}
