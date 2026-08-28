import Foundation

/// Pattern-matches secrets in recognised text (docs/03 §3, docs/06 M18).
///
/// Pure and local: no Vision, no network. The helper runs this on OCR output; the editor
/// runs it on the find-field query. Every detector below is documented and has table-driven
/// tests in `SecretScannerTests`.
///
/// Detectors, in priority order (overlapping hits keep the earlier / longer one):
///
/// 1. **JWT** — three base64url segments; the header is `{"…` so it starts with `eyJ`.
/// 2. **Credit card** — 13–19 digits with optional spaces/dashes, then
/// [Luhn](https://en.wikipedia.org/wiki/Luhn_algorithm).
/// 3. **IBAN** — ISO 13616 shape, then the mod-97 checksum.
/// 4. **Email** — addr-spec with a real TLD, not `user@localhost`.
/// 5. **Phone** — separators or a leading `+`, so a 16-digit card is not a phone.
/// 6. **API key** — known prefixes (AWS, Stripe, GitHub, …) plus a high-entropy fallback.
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

    // Compiled once. Each pattern is a programmer constant; a compile failure here is a
    // bug in this file, not in user input.

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

    // MARK: - Finders

    private static func find(
        pattern: NSRegularExpression,
        kind: SecretKind,
        in text: String,
        transform: ((String) -> String)? = nil
    ) -> [SecretMatch] {
        matches(pattern, in: text).compactMap { result in
            guard result.range.location != NSNotFound else { return nil }
            let raw = (text as NSString).substring(with: result.range)
            let value = transform?(raw) ?? raw
            return SecretMatch(kind: kind, text: value, location: result.range.location, length: result.range.length)
        }
    }

    private static func findCards(in text: String) -> [SecretMatch] {
        matches(card, in: text).compactMap { result in
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
        matches(iban, in: text).compactMap { result in
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
        for result in matches(apiKeyEntropy, in: text) {
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

    private static func collapsingOverlaps(_ matches: [SecretMatch]) -> [SecretMatch] {
        let ranked = matches.sorted { left, right in
            if left.location != right.location {
                return left.location < right.location
            }
            return left.length > right.length
        }
        var accepted: [SecretMatch] = []
        accepted.reserveCapacity(ranked.count)
        for match in ranked {
            let overlaps = accepted.contains { existing in
                NSIntersectionRange(existing.nsRange, match.nsRange).length > 0
            }
            if !overlaps {
                accepted.append(match)
            }
        }
        return accepted
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
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
