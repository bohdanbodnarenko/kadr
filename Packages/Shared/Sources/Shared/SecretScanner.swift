import Foundation

/// Pattern-matches secrets in recognised text (docs/03 §3, docs/06 M18).
///
/// Pure and local: no Vision, no network. The helper runs this on OCR output; the editor
/// runs it on the find-field query. Every detector below is documented and has table-driven
/// tests in `SecretScannerTests`.
///
/// Detectors, in priority order (overlapping hits keep the earlier / longer one):
///
/// 1. **JWT** — three base64url segments; the header starts with `eyJ`.
/// 2. **Credit card** — 13–19 digits with optional spaces/dashes, then Luhn.
/// 3. **IBAN** — ISO 13616 shape, then the mod-97 checksum.
/// 4. **Email** — addr-spec with a real TLD, not `user@localhost`.
/// 5. **Phone** — separators or a leading `+`, so a 16-digit card is not a phone.
/// 6. **API key** — known prefixes (AWS, Stripe, GitHub, …) plus a high-entropy fallback.
/// 7. **Labelled credential** — the value after `password:`, `token=`, `Bearer ` and the
///    like. Only the value, never the label: redacting the whole line hides which field
///    was censored, and a reviewer needs to see that it was the password (docs/09 U1.6).
public struct SecretScanner: Sendable {
    public init() {}

    /// Built-in detectors over `text`.
    public static func matches(in text: String) -> [SecretMatch] {
        var found: [SecretMatch] = []
        found.append(contentsOf: find(
            pattern: jwt,
            kind: .jwt,
            in: text,
            transform: { $0.filter { !$0.isWhitespace } }
        ))
        found.append(contentsOf: findCards(in: text))
        found.append(contentsOf: findIBANs(in: text))
        found.append(contentsOf: find(pattern: email, kind: .email, in: text))
        found.append(contentsOf: find(pattern: phone, kind: .phone, in: text))
        found.append(contentsOf: findAPIKeys(in: text))
        found.append(contentsOf: findLabelledCredentials(in: text))
        found.append(contentsOf: findURLs(in: text))
        found.append(contentsOf: findIPv4(in: text))
        return collapsingOverlaps(found)
    }

    /// Substring matches for the editor's "Redact all text matching…" field.
    ///
    /// Empty or single-character queries match nothing — a one-letter find would paint the
    /// whole capture. Case-insensitive.
    public static func matches(query: String, in text: String) -> [SecretMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }

        let haystack = text as NSString
        let options: NSString.CompareOptions = [.caseInsensitive]
        var location = 0
        var found: [SecretMatch] = []
        while location < haystack.length {
            let remaining = NSRange(location: location, length: haystack.length - location)
            let hit = haystack.range(of: needle, options: options, range: remaining)
            guard hit.location != NSNotFound else { break }
            found.append(SecretMatch(
                kind: .custom,
                text: haystack.substring(with: hit),
                location: hit.location,
                length: hit.length
            ))
            location = hit.location + max(hit.length, 1)
        }
        return found
    }

    // MARK: - Patterns

    /// `local@domain.tld` — letters/digits/._%+- locally, a dotted domain, TLD ≥ 2 letters.
    ///
    /// Deliberately not RFC 5322: a screenshot OCR of an email is ASCII, and matching
    /// quoted-local or IP-literal forms would mostly produce false positives.
    private static let email = regex(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])

    /// International or national numbers that *look* typed by a human: a `+` country code,
    /// or grouped digits with space / dash / parens. Consecutive 13–19 digits are cards.
    ///
    /// Examples: `+1 (415) 555-2671`, `020 7946 0958`.
    private static let phone = regex(
        #"(\+\d{1,3}[\s.\-]?\(?\d{1,4}\)?[\s.\-]?\d{3,4}[\s.\-]?\d{3,4}"#
            + #"|\b0\d{1,4}[\s.\-]\d{3,4}[\s.\-]\d{3,4}\b"#
            + #"|\(?\d{3}\)?[\s.\-]\d{3}[\s.\-]\d{4})"#,
        options: []
    )

    /// 13–19 digits, optional space or dash between them (how cards are printed).
    private static let card = regex(#"\b(?:\d[ \-]?){13,19}\b"#, options: [])

    /// Country code + check digits + BBAN, optional spaces every four characters.
    private static let iban = regex(#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b"#, options: [])

    /// Three segments separated by dots. The header of a JWT is JSON, so it starts with
    /// `eyJ`. Character class is deliberately loose (`[^\s.]`) because screenshot OCR
    /// routinely substitutes lookalikes (`I`/`l`, Latin/`Cyrillic`) and the review strip
    /// is where the user confirms, not the detector.
    private static let jwt = regex(
        #"eyJ[^\s.]{8,}\.[^\s.]{8,}\.[^\s.]{8,}"#,
        options: []
    )

    /// `https://…` / `http://…` / `www.…` — never a bare domain (docs/16 ED-14).
    private static let url = regex(
        #"((?:https?|ftp)://[^\s<>"']+|www\.[^\s<>"']+)"#,
        options: [.caseInsensitive]
    )

    /// Four dotted decimal groups. Octets are checked in the finder.
    private static let ipv4 = regex(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, options: [])

    /// Known high-confidence prefixes (gitleaks / trufflehog style), then a conservative
    /// entropy fallback. Prefixes:
    ///
    /// * AWS access key: `AKIA` + 16 alphanumerics
    /// * Stripe: `sk_live_` / `sk_test_` / `rk_live_` / `pk_live_` + 16+
    /// * GitHub: `ghp_`, `gho_`, `ghu_`, `ghs_`, `github_pat_`
    /// * Slack: `xox[baprs]-`
    /// * Google: `AIza` + 35
    private static let apiKeyPrefix = regex(
        #"\b(AKIA[0-9A-Z]{16}"#
            + #"|sk_(?:live|test)_[0-9A-Za-z]{16,}"#
            + #"|rk_live_[0-9A-Za-z]{16,}"#
            + #"|pk_(?:live|test)_[0-9A-Za-z]{16,}"#
            + #"|gh[pousr]_[A-Za-z0-9]{20,}"#
            + #"|github_pat_[A-Za-z0-9_]{20,}"#
            + #"|xox[baprs]-[A-Za-z0-9-]{10,}"#
            + #"|AIza[0-9A-Za-z\-_]{35})\b"#,
        options: []
    )

    /// Mixed-charset tokens that are not English and not a SHA-1 hex digest.
    private static let apiKeyEntropy = regex(#"\b[A-Za-z0-9_\-+/=]{24,80}\b"#, options: [])

    /// The words that make whatever follows them a secret.
    ///
    /// This is the detector no amount of pattern matching replaces: `hunter2` is a perfectly
    /// ordinary string, and the only thing that marks it as a password is the word in front
    /// of it. Every other detector recognises the *value*; this one recognises the *label*.
    private static let credentialLabel =
        #"(?:pass(?:word|phrase|wd)?|pwd|secret|client[ _\-]?secret|token|access[ _\-]?token"#
            + #"|refresh[ _\-]?token|api[ _\-]?key|apikey|access[ _\-]?key|private[ _\-]?key"#
            + #"|licen[cs]e[ _\-]?key|auth(?:orization)?|pin|otp|cvv|cvc)"#

    /// `password: "hunter 2"` — a quoted value may contain spaces, so it is matched first.
    private static let quotedCredential = regex(
        credentialLabel + #"\s*[:=]\s*["']([^"'\r\n]{3,})["']"#,
        options: [.caseInsensitive]
    )

    /// `password: hunter2`, `token=abc123`. The value runs to the first space.
    private static let bareCredential = regex(
        credentialLabel + #"\s*[:=]\s*([^\s"']{3,})"#,
        options: [.caseInsensitive]
    )

    /// `Authorization: Bearer eyJ…` — the separator is the space after the scheme name,
    /// which is the one place a credential has no colon in front of it.
    private static let bearerCredential = regex(
        #"\bbearer\s+([^\s"']{8,})"#,
        options: [.caseInsensitive]
    )

    // MARK: - Finders

    private static func find(
        pattern: NSRegularExpression,
        kind: SecretKind,
        in text: String,
        transform: ((String) -> String)? = nil
    ) -> [SecretMatch] {
        matchResults(pattern, in: text).compactMap { result in
            guard result.range.location != NSNotFound else { return nil }
            let raw = (text as NSString).substring(with: result.range)
            let value = transform?(raw) ?? raw
            return SecretMatch(kind: kind, text: value, location: result.range.location, length: result.range.length)
        }
    }

    private static func findCards(in text: String) -> [SecretMatch] {
        matchResults(card, in: text).compactMap { result in
            let raw = (text as NSString).substring(with: result.range)
            let digits = raw.filter(\.isNumber)
            guard digits.count >= 13, digits.count <= 19, luhnIsValid(digits) else { return nil }
            return SecretMatch(
                kind: .creditCard,
                text: digits,
                location: result.range.location,
                length: result.range.length
            )
        }
    }

    private static func findIBANs(in text: String) -> [SecretMatch] {
        matchResults(iban, in: text).compactMap { result in
            let raw = (text as NSString).substring(with: result.range)
            let compact = raw.replacingOccurrences(of: " ", with: "").uppercased()
            guard ibanChecksumIsValid(compact) else { return nil }
            return SecretMatch(
                kind: .iban,
                text: compact,
                location: result.range.location,
                length: result.range.length
            )
        }
    }

    private static func findAPIKeys(in text: String) -> [SecretMatch] {
        var found = find(pattern: apiKeyPrefix, kind: .apiKey, in: text)
        for result in matchResults(apiKeyEntropy, in: text) {
            let raw = (text as NSString).substring(with: result.range)
            guard looksLikeHighEntropyKey(raw) else { continue }
            found.append(SecretMatch(
                kind: .apiKey,
                text: raw,
                location: result.range.location,
                length: result.range.length
            ))
        }
        return found
    }

    /// Values a label vouched for, reported without the label.
    ///
    /// The range returned is the capture group's, not the whole match's — so
    /// `password: hunter2` proposes a box over `hunter2` alone. Redacting the label too
    /// would hide *which* field was censored, and a reviewer accepting a candidate needs to
    /// see that it was the password rather than the username (docs/09 U1.6).
    private static func findLabelledCredentials(in text: String) -> [SecretMatch] {
        var found: [SecretMatch] = []
        // Bearer first: `Authorization: Bearer abc…` also matches the bare pattern, whose
        // "value" would be the word `Bearer` itself.
        for pattern in [bearerCredential, quotedCredential, bareCredential] {
            for result in matchResults(pattern, in: text) {
                let range = result.range(at: 1)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                let value = (text as NSString).substring(with: range)
                guard !isPlaceholder(value), !isAuthenticationScheme(value) else { continue }
                found.append(SecretMatch(
                    kind: .credential,
                    text: value,
                    location: range.location,
                    length: range.length
                ))
            }
        }
        return found
    }

    /// `scheme://…` or `www.…` only — never a bare domain (docs/16 ED-14).
    private static func findURLs(in text: String) -> [SecretMatch] {
        find(pattern: url, kind: .url, in: text)
    }

    /// Dotted IPv4 with each octet 0…255.
    private static func findIPv4(in text: String) -> [SecretMatch] {
        matchResults(ipv4, in: text).compactMap { result in
            let raw = (text as NSString).substring(with: result.range)
            let parts = raw.split(separator: ".")
            guard parts.count == 4,
                  parts.allSatisfy({ octet in
                      octet == String(Int(octet) ?? -1) && (0 ... 255).contains(Int(octet) ?? -1)
                  })
            else {
                return nil
            }
            return SecretMatch(
                kind: .ipAddress,
                text: raw,
                location: result.range.location,
                length: result.range.length
            )
        }
    }

    /// Whether a "value" is really the name of an authentication scheme, which means the
    /// secret is the word after it rather than this one.
    private static func isAuthenticationScheme(_ value: String) -> Bool {
        ["bearer", "basic", "digest", "token", "negotiate"].contains(value.lowercased())
    }

    /// Whether a value is the *absence* of a secret: an already-masked field, or the
    /// punctuation a form leaves behind. Proposing a redaction over `••••••` is noise in
    /// the review strip, and noise is what makes a review step get skipped.
    private static func isPlaceholder(_ value: String) -> Bool {
        let masks: Set<Character> = ["*", "•", "●", "·", "-", "_", ".", "#", "x", "X"]
        return value.allSatisfy { masks.contains($0) }
    }

    // MARK: - Checksums

    /// Luhn (mod-10) as used on payment cards. Double every second digit from the right;
    /// a valid number sums to a multiple of 10.
    public static func luhnIsValid(_ digits: String) -> Bool {
        guard digits.allSatisfy(\.isNumber), digits.count >= 13 else { return false }
        var sum = 0
        var doubleIt = false
        for character in digits.reversed() {
            guard let value = character.wholeNumberValue else { return false }
            var term = value
            if doubleIt {
                term *= 2
                if term > 9 {
                    term -= 9
                }
            }
            sum += term
            doubleIt.toggle()
        }
        return sum % 10 == 0
    }

    /// ISO 13616: move the first four characters to the end, A=10…Z=35, remainder 1 mod 97.
    public static func ibanChecksumIsValid(_ compact: String) -> Bool {
        let compact = compact.uppercased()
        guard compact.count >= 15, compact.count <= 34 else { return false }
        let letters = CharacterSet.letters
        let alphanumerics = CharacterSet.alphanumerics
        guard compact.unicodeScalars.allSatisfy({ alphanumerics.contains($0) }) else { return false }
        guard compact.prefix(2).unicodeScalars.allSatisfy({ letters.contains($0) }) else { return false }

        let rearranged = String(compact.dropFirst(4) + compact.prefix(4))
        var remainder = 0
        for character in rearranged {
            if let digit = character.wholeNumberValue {
                remainder = (remainder * 10 + digit) % 97
            } else if let ascii = character.asciiValue, character.isASCII, character.isLetter {
                let value = Int(ascii - 65) + 10
                remainder = (remainder * 100 + value) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    /// Shannon entropy in bits/char. Random tokens sit near 4–5; English words sit lower.
    public static func shannonEntropy(_ string: String) -> Double {
        guard !string.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in string {
            counts[character, default: 0] += 1
        }
        let length = Double(string.count)
        return counts.values.reduce(0) { partial, count in
            let probability = Double(count) / length
            return partial - probability * log2(probability)
        }
    }

    // MARK: - Internals

    private static func looksLikeHighEntropyKey(_ token: String) -> Bool {
        guard token.count >= 24, token.count <= 80 else { return false }
        // `name=value` is an assignment, not a key. Base64 padding is the only `=` a real
        // token carries, and it is always at the end.
        if String(token.reversed().drop(while: { $0 == "=" })).contains("=") {
            return false
        }
        // A file path is the single most common long mixed-case token in a screenshot of a
        // terminal, and it is not a credential.
        if looksLikeAPath(token) {
            return false
        }
        // Git SHAs and similar hex blobs are common in screenshots and are not keys.
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if token.unicodeScalars.allSatisfy({ hex.contains($0) }) {
            return false
        }
        // A UUID with hyphens is an identifier, not a credential.
        if token.filter({ $0 == "-" }).count >= 3, token.count <= 36 {
            return false
        }

        let classes = characterClasses(in: token)
        guard classes >= 3 else { return false }
        return shannonEntropy(token) >= 3.5
    }

    /// Slash-separated runs of plain words: `Users/alice/Library/Application`.
    ///
    /// Base64 tokens contain slashes too, which is why the test is on the *segments*
    /// rather than on the slash — a segment of letters only is a directory name.
    private static func looksLikeAPath(_ token: String) -> Bool {
        let segments = token.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            segment.allSatisfy(\.isLetter)
        }
    }

    private static func characterClasses(in token: String) -> Int {
        var classes = 0
        if token.contains(where: { $0.isUppercase && $0.isLetter }) {
            classes += 1
        }
        if token.contains(where: { $0.isLowercase && $0.isLetter }) {
            classes += 1
        }
        if token.contains(where: \.isNumber) {
            classes += 1
        }
        if token.contains(where: { !$0.isLetter && !$0.isNumber }) {
            classes += 1
        }
        return classes
    }

    /// Overlapping hits, resolved: same-kind spans merge, different-kind spans defer to
    /// whichever started first and ran longest.
    ///
    /// Merging matters for the same kind because two detectors finding overlapping halves
    /// of one card number would otherwise redact one half and leave the other visible —
    /// the worst possible outcome for a security feature. Different kinds are *not* merged,
    /// because a box covering an email and a phone number has to be labelled one of them,
    /// and a mislabelled candidate is one a reviewer accepts without reading.
    private static func collapsingOverlaps(_ matches: [SecretMatch]) -> [SecretMatch] {
        let ranked = matches.sorted { left, right in
            // Precedence first: when two detectors disagree about a span, the one that
            // knows more about it wins. A labelled credential knows the value is a secret
            // *and* where the value starts; an entropy guess knows neither.
            if precedence(left.kind) != precedence(right.kind) {
                return precedence(left.kind) < precedence(right.kind)
            }
            if left.location != right.location {
                return left.location < right.location
            }
            return left.length > right.length
        }

        var accepted: [SecretMatch] = []
        accepted.reserveCapacity(ranked.count)
        for match in ranked {
            // Touching counts as overlapping for the merge: two adjacent halves of one
            // secret leave no gap between them.
            if let index = accepted.firstIndex(where: { existing in
                existing.kind == match.kind && touchesOrOverlaps(existing, match)
            }) {
                accepted[index] = merged(accepted[index], match)
                continue
            }
            let clashes = accepted.contains { existing in
                NSIntersectionRange(existing.nsRange, match.nsRange).length > 0
            }
            if !clashes {
                accepted.append(match)
            }
        }
        return accepted.sorted { $0.location < $1.location }
    }

    /// How much a detector knows, lowest first. Ties are broken by position and length.
    private static func precedence(_ kind: SecretKind) -> Int {
        switch kind {
        case .credential: 0
        case .jwt: 1
        case .creditCard: 2
        case .iban: 3
        case .email: 4
        case .phone: 5
        case .apiKey: 6
        case .url: 7
        case .ipAddress: 8
        case .custom: 9
        }
    }

    private static func touchesOrOverlaps(_ lhs: SecretMatch, _ rhs: SecretMatch) -> Bool {
        let leftEnd = lhs.location + lhs.length
        let rightEnd = rhs.location + rhs.length
        return lhs.location <= rightEnd && rhs.location <= leftEnd
    }

    /// One span covering both, keeping the text of whichever contributed more of it.
    private static func merged(_ lhs: SecretMatch, _ rhs: SecretMatch) -> SecretMatch {
        let location = min(lhs.location, rhs.location)
        let end = max(lhs.location + lhs.length, rhs.location + rhs.length)
        return SecretMatch(
            kind: lhs.kind,
            text: lhs.length >= rhs.length ? lhs.text : rhs.text,
            location: location,
            length: end - location
        )
    }

    private static func matchResults(_ pattern: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func regex(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("SecretScanner pattern is a compile-time constant: \(error)")
        }
    }
}
