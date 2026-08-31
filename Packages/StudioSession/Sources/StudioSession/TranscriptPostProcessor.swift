import Foundation

/// Hallucination filtering and Unicode-correct word replacement (docs/13 T2.6).
///
/// Applied *after* recognition, never as an `initial_prompt`: stuffing vocabulary into a
/// prompt is a known hallucination amplifier. Replacement uses lookarounds over letter /
/// mark / number classes, minus non-spaced scripts, because `\b` is wrong for most of the
/// world.
public struct TranscriptPostProcessor: Sendable {
    public var replacements: [String: String]

    public init(replacements: [String: String] = [:]) {
        self.replacements = replacements
    }

    public func processed(_ transcript: Transcript) -> Transcript {
        var words = transcript.words.map { word in
            var copy = word
            copy.text = Self.cleaned(word.text)
            return copy
        }
        words = Self.droppingHallucinations(words)
        words = Self.droppingRepetitionLoops(words)
        if !replacements.isEmpty {
            words = words.map { word in
                var copy = word
                copy.text = Self.replacing(in: word.text, using: replacements)
                return copy
            }
        }
        return Transcript(
            words: words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            audioContentHash: transcript.audioContentHash,
            localeIdentifier: transcript.localeIdentifier,
            engine: transcript.engine,
            version: transcript.version
        )
    }

    // MARK: - Cleaning

    /// Drops whisper-style tags, bracketed asides, and collapsed whitespace.
    public static func cleaned(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"<([A-Za-z][A-Za-z0-9_-]*)\b[^>]*>.*?</\1>"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+, "#, with: ", ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func droppingHallucinations(_ words: [TranscriptWord]) -> [TranscriptWord] {
        words.filter { word in
            let folded = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if folded.isEmpty {
                return false
            }
            let upper = folded.uppercased()
            if upper.contains("BLANK_AUDIO") || upper.contains("MUSIC") && folded.hasPrefix("[") {
                return false
            }
            return true
        }
    }

    /// Drops a run of the same token repeating four or more times — the loop Apple's
    /// engines (and whisper) fall into on silence and on music.
    static func droppingRepetitionLoops(_ words: [TranscriptWord]) -> [TranscriptWord] {
        guard words.count >= 4 else { return words }
        var kept: [TranscriptWord] = []
        var index = 0
        while index < words.count {
            let token = words[index].normalized
            var run = 1
            while index + run < words.count, words[index + run].normalized == token, !token.isEmpty {
                run += 1
            }
            if run >= 4 {
                kept.append(contentsOf: words[index ..< (index + 2)])
                index += run
                continue
            }
            kept.append(words[index])
            index += 1
        }
        return kept
    }

    // MARK: - Replacement

    /// Longest-first replacement using lookarounds over letter/mark/number classes, with a
    /// substring fallback for scripts that do not use spaces.
    public static func replacing(in text: String, using map: [String: String]) -> String {
        guard !map.isEmpty else { return text }
        let ordered = map.keys.sorted { $0.count > $1.count }
        var result = text
        for source in ordered {
            guard let replacement = map[source] else { continue }
            if Self.usesSpaces(source) {
                result = Self.replaceSpaced(source, with: replacement, in: result)
            } else {
                result = result.replacingOccurrences(of: source, with: replacement)
            }
        }
        return result
    }

    /// `\b` is wrong for German compounds and for anything without spaces. Look around a
    /// letter/mark/number that is *not* a non-spaced script.
    private static func replaceSpaced(_ source: String, with replacement: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: source)
        let pattern = "(?<![\(Self.spacedLetterClass)])\(escaped)(?![\(Self.spacedLetterClass)])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static let spacedLetterClass = #"\p{L}\p{M}\p{N}"#

    private static func usesSpaces(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            let value = scalar.value
            // Han, Hiragana, Katakana, Hangul, Thai — substring fallback for these.
            return (0x1100 ... 0x11FF).contains(value)
                || (0x3040 ... 0x30FF).contains(value)
                || (0x3400 ... 0x9FFF).contains(value)
                || (0xAC00 ... 0xD7AF).contains(value)
                || (0x0E00 ... 0x0E7F).contains(value)
        }
    }
}
