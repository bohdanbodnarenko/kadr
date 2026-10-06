import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// Correcting a transcript word from the studio (docs/18 Phase 4).
@MainActor
@Suite("Studio word correction")
struct StudioWordCorrectionTests {
    @Test("A correction is one undoable change, and a no-op is none")
    func undoable() async throws {
        let folder = StudioPlaybackFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try await StudioPlaybackFixtures.model(in: folder, seconds: 1)
        let word = TranscriptWord(text: "helo", start: 0.1, end: 0.4)

        studio.correctWord(word, to: "helo")
        #expect(!studio.canUndo, "correcting to what was heard changes nothing")

        studio.correctWord(word, to: "hello")
        #expect(studio.edit.transcriptCorrections[word.id] == "hello")
        studio.undo()
        #expect(studio.edit.transcriptCorrections[word.id] == nil)
    }
}
