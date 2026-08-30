import Foundation

/// A script to read while recording (docs/08, teleprompter).
///
/// Lives beside the transcript work rather than in the recording package because it is the
/// same problem seen from the other end: the cut planner takes speech and finds the words,
/// and this takes words and follows the speech. They share the normalisation, and putting
/// them together is what stops the two drifting into disagreeing about what a word is.
///
/// The text is split once, at construction. Every consumer wants either words — for
/// following along — or lines, for drawing, and recomputing either while somebody is
/// reading aloud is work done sixty times a second for an answer that never changes.
public struct TeleprompterScript: Sendable, Hashable, Codable {
    /// One word of the script, and where it sits.
    public struct Word: Sendable, Hashable, Codable {
        /// As written, punctuation and capitals intact, because this is what gets drawn.
        public var text: String
        /// Lowercased and stripped of punctuation, for comparing against what was heard.
        public var normalized: String
        /// Which line it belongs to, so highlighting a word can scroll to its line.
        public var line: Int

        public init(text: String, normalized: String, line: Int) {
            self.text = text
            self.normalized = normalized
            self.line = line
        }
    }

    /// One line as the author wrote it.
    ///
    /// Authored lines rather than wrapped ones: where the text wraps depends on the panel's
    /// width and the reader's font size, which are not the script's business. A paragraph
    /// break is, because somebody put it there.
    public struct Line: Sendable, Hashable, Codable {
        public var text: String
        /// The range of `words` this line covers, as a half-open interval.
        public var wordRange: Range<Int>

        public init(text: String, wordRange: Range<Int>) {
            self.text = text
            self.wordRange = wordRange
        }
    }

    public let text: String
    public let words: [Word]
    public let lines: [Line]

    public init(text: String) {
        self.text = text
        var words: [Word] = []
        var lines: [Line] = []

        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let start = words.count
            for token in raw.split(whereSeparator: \.isWhitespace) {
                let spelling = String(token)
                words.append(Word(
                    text: spelling,
                    normalized: TeleprompterScript.normalize(spelling),
                    line: index
                ))
            }
            // Blank lines are kept. They are how somebody spaced their script out, and a
            // prompter that closes the gaps re-flows the reading they rehearsed against.
            lines.append(Line(text: raw, wordRange: start ..< words.count))
        }

        self.words = words
        self.lines = lines
    }

    public var isEmpty: Bool {
        words.isEmpty
    }

    /// Normalises a word for comparison.
    ///
    /// Case and punctuation go, because a recogniser does not hear a comma and has its own
    /// opinion about capitals. Everything else stays — including the digits in "macOS 26",
    /// which a stricter filter would throw away along with the word that identifies where
    /// in the script somebody is.
    public static func normalize(_ word: some StringProtocol) -> String {
        String(word.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "'"
        })
    }

    /// Which line a word index falls on, clamped into the script.
    public func line(ofWord index: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        return words[min(max(index, 0), words.count - 1)].line
    }

    /// How far through the script a word index is, from zero to one.
    public func progress(atWord index: Int) -> Double {
        guard words.count > 1 else { return words.isEmpty ? 0 : 1 }
        return min(max(Double(index) / Double(words.count - 1), 0), 1)
    }
}

/// Scrolling a script at a steady rate (docs/08, teleprompter).
///
/// The fallback under everything else, and on most machines the whole feature: it needs no
/// microphone, no permission and no model, and a reader who has rehearsed against a rate
/// finds it more predictable than one that reacts to them.
public struct TeleprompterPacing: Sendable, Hashable, Codable {
    /// How fast the script advances, in words per minute.
    ///
    /// A comfortable presenting pace is around 130; audiobook narration sits near 150 and
    /// conversational speech runs to 180. The default is deliberately below all of them,
    /// because a prompter that runs ahead of the reader is worse than one that waits.
    public var wordsPerMinute: Double

    public static let defaultRate: Double = 120
    public static let slowest: Double = 60
    public static let fastest: Double = 240

    public init(wordsPerMinute: Double = defaultRate) {
        self.wordsPerMinute = min(max(wordsPerMinute, Self.slowest), Self.fastest)
    }

    /// Which word the reader should be on after `elapsed` seconds.
    ///
    /// Fractional on purpose. The panel scrolls continuously, and rounding here would make
    /// it step a word at a time — which is visible, and reads as a stutter rather than as
    /// a scroll.
    public func position(after elapsed: TimeInterval) -> Double {
        max(elapsed, 0) / 60 * wordsPerMinute
    }

    /// How long a script takes to read at this rate.
    public func duration(of script: TeleprompterScript) -> TimeInterval {
        guard wordsPerMinute > 0 else { return 0 }
        return Double(script.words.count) / wordsPerMinute * 60
    }
}
