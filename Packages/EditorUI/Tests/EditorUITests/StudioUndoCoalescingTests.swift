import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// One gesture, one undo step (docs/11 S2).
///
/// A `Slider` sends a change per pixel of travel, and the studio pushed a snapshot for
/// every one — so a single drag consumed the whole fifty-deep stack and Undo afterwards
/// nudged the value by a hair with everything before the drag already gone. This is
/// docs/07 C2 repeating one app over; the annotation editor learned it in U0.2.
@MainActor
@Suite("Studio undo coalescing")
struct StudioUndoCoalescingTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-undo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(in folder: URL) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        let document = SessionDocument(session: session)
        try document.write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 10,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    // MARK: - Undo coalescing (docs/11 S2)

    /// One drag of one slider is one undo step. A `Slider` sends a change per pixel of
    /// travel, and without coalescing a single drag pushed forty snapshots — enough to
    /// consume the whole fifty-deep stack, so Undo afterwards nudged the value by a hair
    /// and everything before the drag was gone.
    @Test("A slider drag is one undo step, not one per tick")
    func aDragIsOneUndoStep() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let before = studio.edit.camera.sizeFraction

        for step in 1 ... 40 {
            studio.change(coalescingAs: "camera.size") {
                $0.camera.sizeFraction = 0.1 + Double(step) * 0.01
            }
        }
        #expect(studio.edit.camera.sizeFraction != before)

        studio.undo()
        #expect(studio.edit.camera.sizeFraction == before, "undo landed mid-drag rather than before it")
        #expect(!studio.canUndo, "the drag left more than one step on the stack")
    }

    /// Releasing one slider and dragging another is two steps, which is the whole reason
    /// the gesture is named rather than being a bare "coalesce the next one" flag.
    @Test("Two different sliders are two undo steps")
    func differentSlidersAreSeparateSteps() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let size = studio.edit.camera.sizeFraction
        let roundness = studio.edit.camera.roundness

        studio.change(coalescingAs: "camera.size") { $0.camera.sizeFraction = 0.4 }
        studio.change(coalescingAs: "camera.size") { $0.camera.sizeFraction = 0.5 }
        studio.change(coalescingAs: "camera.roundness") { $0.camera.roundness = 0.2 }

        studio.undo()
        #expect(studio.edit.camera.roundness == roundness)
        #expect(studio.edit.camera.sizeFraction == 0.5, "undoing the second slider also undid the first")
        studio.undo()
        #expect(studio.edit.camera.sizeFraction == size)
    }

    /// An uncoalesced change still gets its own step, so a toggle or a button is unaffected.
    @Test("Discrete changes each get their own undo step")
    func discreteChangesAreSeparate() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        studio.change { $0.showsClicks = false }
        studio.change { $0.showsKeystrokes = false }

        studio.undo()
        #expect(studio.edit.showsKeystrokes)
        #expect(!studio.edit.showsClicks)
    }

    /// Undo ends the gesture: a slider tick arriving afterwards must not merge into the
    /// step that was just undone, or the stack would quietly rewrite its own history.
    @Test("A tick after undo starts a new step")
    func undoEndsTheGesture() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let before = studio.edit.camera.sizeFraction

        studio.change(coalescingAs: "camera.size") { $0.camera.sizeFraction = 0.4 }
        studio.undo()
        #expect(studio.edit.camera.sizeFraction == before)

        studio.change(coalescingAs: "camera.size") { $0.camera.sizeFraction = 0.5 }
        studio.undo()
        #expect(studio.edit.camera.sizeFraction == before)
    }
}
