import Foundation

/// Reading OCR's digit lookalikes as digits before looking for card numbers
/// (docs/17 T-REL-8).
extension SecretScanner {
    /// `text` with the glyphs OCR mistakes for digits — `O` for 0, `l` `I` `|` for 1,
    /// `Z` for 2, `S` for 5, `B` for 8 — read as digits, but only inside runs that are
    /// mostly digits already (docs/17 T-REL-8).
    ///
    /// Mostly-digits is the guard against reading words as numbers. A card number that
    /// comes out of OCR as `4111 l111 1111 1111` is still a card, and still has to be
    /// redacted: an auto-redaction that silently misses one is a privacy defect. Luhn,
    /// checked afterwards, is what keeps a mis-read that is not a card from being one.
    static func digitized(_ text: String) -> String {
        let units = Array(text.utf16)
        var output = units
        let map: [UInt16: UInt16] = [
            "O", "o", "D", "Q", "I", "l", "|", "!", "Z", "z", "S", "s", "B"
        ].reduce(into: [:]) { result, glyph in
            let digit: Character = switch glyph {
            case "O", "o", "D", "Q": "0"
            case "I", "l", "|", "!": "1"
            case "Z", "z": "2"
            case "S", "s": "5"
            default: "8"
            }
            result[glyph.utf16.first ?? 0] = digit.utf16.first ?? 0
        }
        for result in matchResults(digitLikeRun, in: text) {
            let range = result.range
            let run = units[range.location ..< range.location + range.length]
            let digits = run.count(where: { (48 ... 57).contains($0) })
            let glyphs = run.count(where: { map[$0] != nil })
            // At least ten real digits, and the lookalikes a small minority of them.
            guard digits >= 10, glyphs * 4 <= digits else { continue }
            mapGroups(in: range, units: units, into: &output, using: map)
        }
        return String(decoding: output, as: UTF16.self)
    }

    /// Maps lookalikes group by group (a group is what sits between spaces and dashes).
    ///
    /// A group is read as digits only if it has at least as many real digits as
    /// lookalikes, and does not run on into a word outside the run — so the `s` of
    /// `4111… suffix` stays a letter.
    private static func mapGroups(
        in range: NSRange,
        units: [UInt16],
        into output: inout [UInt16],
        using map: [UInt16: UInt16]
    ) {
        let separators: Set<UInt16> = [32, 45]
        let end = range.location + range.length
        var start = range.location
        while start < end {
            var stop = start
            while stop < end, !separators.contains(units[stop]) {
                stop += 1
            }
            let group = units[start ..< stop]
            let digits = group.count { (48 ... 57).contains($0) }
            let glyphs = group.count { map[$0] != nil }
            let before = start > 0 ? units[start - 1] : 32
            let after = stop < units.count ? units[stop] : 32
            let touchesWord = isLetter(before) || isLetter(after)
            if digits > 0, digits >= glyphs, !touchesWord {
                for index in start ..< stop {
                    if let digit = map[units[index]] {
                        output[index] = digit
                    }
                }
            }
            start = stop + 1
        }
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        (65 ... 90).contains(unit) || (97 ... 122).contains(unit)
    }
}
