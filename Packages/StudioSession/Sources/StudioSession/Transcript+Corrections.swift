import Foundation

public extension Transcript {
    /// The transcript with the user's corrections in place of what the engine heard
    /// (docs/18 Phase 4, transcript correction).
    ///
    /// Corrections are keyed by the original word's `id` and live in the edit, not in the
    /// transcript file, so transcribing again keeps them for the words that come back the
    /// same and undo reaches them. A blank correction is ignored rather than deleting the
    /// word: cutting a word is what the cut tools are for.
    func applying(corrections: [String: String]) -> Transcript {
        guard !corrections.isEmpty else { return self }
        var corrected = self
        corrected.words = words.map { word in
            guard let replacement = corrections[word.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !replacement.isEmpty
            else { return word }
            var edited = word
            edited.text = replacement
            return edited
        }
        return corrected
    }
}

public extension StudioEdit {
    /// Records `text` as what `word` should say, or clears the correction when `text` is
    /// blank or matches what was heard.
    mutating func correct(_ word: TranscriptWord, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == word.text {
            transcriptCorrections.removeValue(forKey: word.id)
        } else {
            transcriptCorrections[word.id] = trimmed
        }
    }
}
