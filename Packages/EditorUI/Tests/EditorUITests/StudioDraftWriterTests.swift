import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// The draft autosave, written off the main actor (docs/11 S2).
///
/// What matters is ordering: the background writer must never put an older draft on disk
/// after a newer one, and never put *any* draft back after a close has committed.
@MainActor
@Suite("Studio draft writer")
struct StudioDraftWriterTests {
    private func session() throws -> (RecordingSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-draft-\(UUID().uuidString)", isDirectory: true)
        let session = RecordingSession.create(in: root, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 10,
            hasBakedCursor: true
        ))
        return (session, root)
    }

    private func draft(_ session: RecordingSession) -> StudioEdit? {
        guard let data = try? Data(contentsOf: session.draftEditURL) else { return nil }
        return try? JSONDecoder().decode(StudioEdit.self, from: data)
    }

    @Test("An older generation never overwrites a newer one")
    func olderWritesAreDropped() async throws {
        let (session, root) = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudioDraftWriter(document: SessionDocument(session: session))
        var newer = StudioEdit.untouched(duration: 10)
        newer.showsClicks = false
        let older = StudioEdit.untouched(duration: 10)

        await writer.write(newer, generation: 2)
        await writer.write(older, generation: 1)
        #expect(draft(session)?.showsClicks == false)
        #expect(writer.state.written == 2)
    }

    @Test("A flush fences off writes that were still queued")
    func flushFencesQueuedWrites() async throws {
        let (session, root) = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = SessionDocument(session: session)
        let writer = StudioDraftWriter(document: document)
        let edit = StudioEdit.untouched(duration: 10)

        writer.writeSynchronously(edit, generation: 3)
        try document.commit(edit)
        #expect(!session.needsRecovery)

        // A background write from before the flush arrives late: it must not recreate the draft.
        await writer.write(edit, generation: 3)
        await writer.write(edit, generation: 2)
        #expect(!FileManager.default.fileExists(atPath: session.draftEditURL.path))
        #expect(writer.state.fence == 3)

        // Work after the flush is newer, and is written.
        await writer.write(edit, generation: 4)
        #expect(FileManager.default.fileExists(atPath: session.draftEditURL.path))
    }

    @Test("Editing after the first change autosaves off the main actor, and close still settles")
    func laterChangesReachTheDiskAndCloseSettles() async throws {
        let (session, root) = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = try #require(StudioDocumentModel(session: session))

        studio.change { $0.showsClicks = false }
        #expect(session.needsRecovery, "the first change must put a draft on disk at once")

        for step in 1 ... 20 {
            studio.change(coalescingAs: "camera.size") { $0.camera.sizeFraction = 0.1 + Double(step) * 0.01 }
        }
        studio.commitOnClose()
        #expect(!session.needsRecovery)
        #expect(draft(session) == nil, "commit clears the draft")

        // Anything the background writer still had queued lands now, and must be fenced.
        try await Task.sleep(for: StudioDocumentModel.draftInterval + .milliseconds(200))
        #expect(!session.needsRecovery, "a queued autosave landed after the close")

        let reopened = try #require(StudioDocumentModel(session: session))
        #expect(abs(reopened.edit.camera.sizeFraction - 0.3) < 0.0001)
    }
}
