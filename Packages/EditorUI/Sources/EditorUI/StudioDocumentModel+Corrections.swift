import Foundation
import StudioSession

@MainActor
public extension StudioDocumentModel {
    /// Replaces what the engine heard for `word` with `text`, as one undoable change.
    /// Blank, or the same as what was heard, removes the correction (docs/18 Phase 4).
    func correctWord(_ word: TranscriptWord, to text: String) {
        let before = edit.transcriptCorrections[word.id]
        var probe = edit
        probe.correct(word, to: text)
        guard probe.transcriptCorrections[word.id] != before else { return }
        change { $0.correct(word, to: text) }
    }
}
