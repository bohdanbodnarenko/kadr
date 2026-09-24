import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// Deleting the clip that was named, and not overwriting an edit that could not be read
/// (docs/17 T-STU-8, T-STU-9).
@MainActor
@Suite("Studio clip lifecycle")
struct StudioClipLifecycleTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-studio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(in folder: URL) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data(repeating: 0, count: 64).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            frameRate: 60,
            duration: 10,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    /// docs/17 T-STU-9: opening does not autosave over an edit it could not read.
    @Test("An unreadable edit is kept aside and the user is told")
    func unreadableEditIsKept() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try model(in: folder)
        let session = first.session
        // A clip list of the wrong shape: what a future or damaged edit looks like here.
        try Data("{\"clips\": \"a string where clips should be\"}".utf8).write(to: session.editURL)
        try? FileManager.default.removeItem(at: session.draftEditURL)

        let reopened = try #require(StudioDocumentModel(session: session))
        #expect(reopened.failure != nil)
        let kept = try FileManager.default.contentsOfDirectory(atPath: session.directory.path)
            .filter { $0.contains("unreadable") }
        #expect(kept.count == 1)
    }

    /// docs/17 T-STU-8: the clip the user named goes, not the one under the playhead.
    @Test("Removing a clip by id removes that clip, wherever the playhead is")
    func removeNamedClip() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 4
        studio.splitAtPlayhead()
        let second = studio.edit.clips.clips[1].id
        let first = studio.edit.clips.clips[0].id
        studio.selectedClip = second
        studio.playhead = 1
        studio.removeClip(id: second)
        #expect(studio.edit.clips.clips.map(\.id) == [first])
        #expect(studio.selectedClip == nil)
        #expect(studio.clipID(at: 1) == first)
    }
}
