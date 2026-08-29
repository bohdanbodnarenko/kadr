import Foundation

/// Following a reader through a script by what they are saying (docs/08, teleprompter).
///
/// The problem is not matching words — it is matching them when the recogniser is wrong,
/// the reader skips a line, paraphrases half a sentence, or says "the" for the ninetieth
/// time. A naive search for the last heard word lands on whichever "the" it likes and the
/// script leaps somewhere else, which is worse than not following at all: a prompter that
/// scrolls smoothly and slightly wrong can be read around, and one that teleports cannot.
///
/// So the rules are conservative, and each of them is a refusal:
///
/// * Match a *phrase*, never a word. Several words in a row agreeing is evidence; one word
///   agreeing is a coincidence, and short common words are nothing but coincidences.
/// * Look only a little way ahead, and barely behind. A reader is near where they were a
///   second ago. A match forty words away is more likely a repeated phrase than a jump.
/// * Move only on enough agreement. Below the threshold the position holds, which is what
///   somebody going off script wants: the prompter waits where they left it.
/// * Never move backwards except by a word or two. Re-reading a phrase is common;
///   travelling back up the page because a recogniser produced an early word is not.
///
/// Pure and synchronous. Everything difficult about following speech is in this decision,
/// and none of it needs a microphone to test.
public struct SpeechFollower: Sendable {
    /// How many script words ahead of the current position to consider.
    ///
    /// Wide enough to survive a skipped sentence, narrow enough that a phrase repeated
    /// later in the script is out of range. About fifteen seconds of speech.
    public var lookahead: Int
    /// How far back a match may be found. Small: re-reading a phrase, not turning back.
    public var lookbehind: Int
    /// How many recently heard words are matched at once.
    public var phraseLength: Int
    /// How many of a phrase's words must agree before the position moves.
    public var requiredMatches: Int

    public init(
        lookahead: Int = 40,
        lookbehind: Int = 4,
        phraseLength: Int = 5,
        requiredMatches: Int = 3
    ) {
        self.lookahead = max(lookahead, 1)
        self.lookbehind = max(lookbehind, 0)
        self.phraseLength = max(phraseLength, 1)
        self.requiredMatches = max(requiredMatches, 1)
    }

    /// Where the reader appears to be, given what they have just said.
    ///
    /// - Parameters:
    ///   - heard: recognised words, oldest first. Only the tail is used, so a caller may
    ///     pass the whole transcript so far without it getting slower or less accurate as
    ///     the recording goes on.
    ///   - script: what they are reading.
    ///   - position: where they were, as a word index.
    /// - Returns: the new position, or the old one when nothing matched well enough.
    public func position(
        heard: [String],
        in script: TeleprompterScript,
        from position: Int
    ) -> Int {
        guard !script.words.isEmpty else { return 0 }
        let phrase = Self.normalized(heard.suffix(phraseLength))
        guard phrase.count >= requiredMatches else { return position }

        let start = max(position - lookbehind, 0)
        let end = min(position + lookahead, script.words.count)
        guard start < end else { return position }

        var best: Candidate?
        for candidate in start ..< end {
            let score = Self.score(phrase: phrase, against: script, at: candidate)
            guard score.matches >= requiredMatches else { continue }
            guard let current = best else {
                best = Candidate(index: candidate, matches: score.matches, consumed: score.consumed)
                continue
            }
            if score.isBetter(than: current, distanceFrom: position, candidate: candidate) {
                best = Candidate(index: candidate, matches: score.matches, consumed: score.consumed)
            }
        }

        guard let best else { return position }
        // The reader is *past* the phrase that just matched, not at the start of it.
        let advanced = best.index + best.consumed
        return min(max(advanced, position - lookbehind), script.words.count)
    }

    // MARK: - Scoring

    private struct Candidate {
        let index: Int
        let matches: Int
        let consumed: Int
    }

    private struct Score {
        let matches: Int
        /// How many script words the phrase covered, so the position lands after them.
        let consumed: Int

        /// More agreement wins; ties go to the candidate nearest where the reader already
        /// was, which is what stops an equally-good repeat later in the script from
        /// pulling them forwards.
        func isBetter(than other: Candidate, distanceFrom position: Int, candidate: Int) -> Bool {
            if matches != other.matches {
                return matches > other.matches
            }
            return abs(candidate - position) < abs(other.index - position)
        }
    }

    /// How well a heard phrase lines up with the script starting at an index.
    ///
    /// Words are matched in order and gaps are allowed on both sides, so a reader who skips
    /// a word, or a recogniser that invents one, still scores. What is not allowed is
    /// matching out of order: "the cat sat" and "sat the cat" are different sentences and a
    /// scorer that cannot tell them apart will follow a reader into the wrong paragraph.
    private static func score(
        phrase: [String],
        against script: TeleprompterScript,
        at index: Int
    ) -> Score {
        var matches = 0
        var cursor = index
        var lastMatched = index
        // A small budget for words the script has and the reader skipped. Unbounded, a
        // phrase would match almost anywhere by picking one word from each end of a
        // paragraph.
        let slack = 2

        for word in phrase {
            var probe = cursor
            let limit = min(cursor + slack + 1, script.words.count)
            while probe < limit {
                if script.words[probe].normalized == word {
                    matches += 1
                    lastMatched = probe
                    cursor = probe + 1
                    break
                }
                probe += 1
            }
            if probe >= limit {
                // Not found nearby: the reader said something the script does not have
                // here. Keep going rather than giving up, so one misrecognised word does
                // not throw away an otherwise good match.
                cursor = min(cursor + 1, script.words.count)
            }
            if cursor >= script.words.count {
                break
            }
        }
        return Score(matches: matches, consumed: max(lastMatched - index + 1, 0))
    }

    private static func normalized(_ words: some Sequence<String>) -> [String] {
        words
            .map(TeleprompterScript.normalize)
            .filter { !$0.isEmpty }
    }
}
