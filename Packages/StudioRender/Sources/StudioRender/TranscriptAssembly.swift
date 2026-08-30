import Foundation

/// Turning a timed stretch of recognised text into words (docs/09 U3.6).
///
/// The two speech APIs report at different granularities: `SFSpeechRecognizer` hands back
/// one segment per word, and `SpeechAnalyzer` hands back attributed runs that sometimes
/// cover a whole phrase. The planner wants words, so the coarser shape has to be split —
/// and the split is arithmetic on strings, which means it can be tested without a
/// microphone, a model or a particular version of macOS.
///
/// Time inside a run is apportioned by character count. That is an approximation: nobody
/// speaks at a constant number of characters per second. It is a good enough one because
/// of what the times are *for* — deciding whether the gap between two words is longer than
/// a second, and where inside a pause it is safe to cut. Both survive a few tens of
/// milliseconds of drift, and neither is ever used to cut inside a word.
public enum TranscriptAssembly {
    /// Splits one timed run of text into words, apportioning its duration by character count.
    ///
    /// Returns nothing for a run that is only whitespace: a run with no words in it should
    /// widen the silence around it rather than become a zero-length word in the middle of
    /// the pause, which would stop the planner from proposing the cut at all.
    public static func words(in text: String, start: TimeInterval, end: TimeInterval) -> [TranscriptWord] {
        let tokens = tokens(in: text)
        guard !tokens.isEmpty else { return [] }
        let total = text.count
        let duration = max(0, end - start)
        guard total > 0, duration > 0 else {
            // A run with no duration still describes words; give them all the same instant
            // rather than dropping them, so the text survives even when the times do not.
            return tokens.map { TranscriptWord(text: $0.text, start: start, end: start) }
        }
        return tokens.map { token in
            TranscriptWord(
                text: token.text,
                start: start + duration * Double(token.offset) / Double(total),
                end: start + duration * Double(token.offset + token.text.count) / Double(total)
            )
        }
    }

    /// A word and where it starts, in characters, inside its run.
    private struct Token {
        let text: String
        let offset: Int
    }

    /// Splits on whitespace, keeping each word's character offset so its share of the run's
    /// time can be worked out. Splitting on whitespace rather than on
    /// `enumerateSubstrings(in:options: .byWords)` is deliberate: word enumeration drops
    /// punctuation and would report "don" and "t" for "don't".
    private static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var start = 0
        for (offset, character) in text.enumerated() {
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(Token(text: current, offset: start))
                    current = ""
                }
                start = offset + 1
            } else {
                if current.isEmpty {
                    start = offset
                }
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(Token(text: current, offset: start))
        }
        return tokens
    }
}
