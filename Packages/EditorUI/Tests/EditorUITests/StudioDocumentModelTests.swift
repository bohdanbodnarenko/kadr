import Foundation
import StudioCore
import Testing
@testable import EditorUI

/// Editing a recording in the studio (docs/09 U3).
///
/// The model is where every edit goes, so it is where the behaviour that matters lives:
/// that undo restores whole values rather than reversing steps, that the draft is written
/// as the user works, and that the destructive-looking operations refuse the cases that
/// would lose a recording.
@MainActor
@Suite("Studio document model")
struct StudioDocumentModelTests {
    // MARK: - Fixtures

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-studio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A session with footage, a manifest and whatever telemetry the test wants.
    ///
    /// The footage is a placeholder file rather than a real movie: nothing here decodes a
    /// frame, and a model that refuses to open a session without one would be untestable
    /// for the same reason it would be annoying — the studio has to open before it renders.
    private func makeSession(
        in folder: URL,
        duration: TimeInterval = 10,
        hasBakedCursor: Bool = true,
        telemetry: InputTelemetry = InputTelemetry()
    ) throws -> RecordingSession {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data(repeating: 0, count: 64).write(to: session.screenURL)

        let document = SessionDocument(session: session)
        try document.write(telemetry)
        try document.write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            scale: 2,
            frameRate: 60,
            duration: duration,
            hasBakedCursor: hasBakedCursor,
            hasCamera: false
        ))
        return session
    }

    private func model(
        in folder: URL,
        duration: TimeInterval = 10,
        hasBakedCursor: Bool = true,
        telemetry: InputTelemetry = InputTelemetry()
    ) throws -> StudioDocumentModel {
        let session = try makeSession(
            in: folder,
            duration: duration,
            hasBakedCursor: hasBakedCursor,
            telemetry: telemetry
        )
        return try #require(StudioDocumentModel(session: session))
    }

    // MARK: - Opening

    @Test("A session with footage and a manifest opens")
    func opens() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(studio.edit.duration == 10)
        #expect(studio.manifest.frameRate == 60)
    }

    @Test("A session with no footage does not open")
    func refusesEmptySession() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = RecordingSession.create(in: folder, named: "empty")
        try session.create()
        #expect(StudioDocumentModel(session: session) == nil)
    }

    @Test("A session with no manifest does not open")
    func refusesUnmanifestedSession() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = RecordingSession.create(in: folder, named: "bare")
        try session.create()
        try Data(repeating: 0, count: 8).write(to: session.screenURL)
        #expect(StudioDocumentModel(session: session) == nil)
    }

    /// A recording made without a baked cursor needs one drawn back; one made with a cursor
    /// already in the picture does not, or it gets two.
    @Test("The cursor is drawn back only when it was not recorded", arguments: [true, false])
    func cursorDefaultFollowsTheRecording(baked: Bool) throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder, hasBakedCursor: baked)
        #expect(studio.edit.showsCursor == !baked)
    }

    @Test("Reopening finds the draft rather than starting over")
    func reopensTheDraft() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try makeSession(in: folder)

        let first = try #require(StudioDocumentModel(session: session))
        first.change { $0.showsClicks = false }

        let second = try #require(StudioDocumentModel(session: session))
        #expect(!second.edit.showsClicks, "the draft was not read back")
    }

    // MARK: - Undo

    @Test("An edit can be undone and redone")
    func undoRedo() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(!studio.canUndo)

        studio.change { $0.showsKeystrokes = false }
        #expect(studio.canUndo)
        #expect(!studio.edit.showsKeystrokes)

        studio.undo()
        #expect(studio.edit.showsKeystrokes)
        #expect(studio.canRedo)

        studio.redo()
        #expect(!studio.edit.showsKeystrokes)
    }

    /// A change that changes nothing is not a step: otherwise dragging a slider back to
    /// where it started fills the undo stack with entries that all look identical.
    @Test("A change that changes nothing is not recorded")
    func noOpIsNotAStep() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.change { $0.showsClicks = studio.edit.showsClicks }
        #expect(!studio.canUndo)
    }

    @Test("A new edit clears the redo stack")
    func editClearsRedo() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.change { $0.showsClicks = false }
        studio.undo()
        #expect(studio.canRedo)
        studio.change { $0.showsKeystrokes = false }
        #expect(!studio.canRedo, "redoing past a new edit would restore a state that never existed")
    }

    /// Bounded because an edit is a whole value, and keeping every one of a long session is
    /// a slow leak rather than a feature.
    @Test("The undo stack is bounded")
    func undoIsBounded() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        for step in 0 ..< (StudioDocumentModel.undoDepth + 20) {
            studio.change { $0.camera.sizeFraction = 0.1 + Double(step) * 0.001 }
        }
        var undone = 0
        while studio.canUndo {
            studio.undo()
            undone += 1
        }
        #expect(undone <= StudioDocumentModel.undoDepth)
    }

    @Test("Undoing past the start does nothing rather than crashing")
    func undoAtTheStart() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let opened = studio.edit
        studio.undo()
        studio.redo()
        #expect(studio.edit == opened)
    }

    // MARK: - Zooms

    /// Anchored at the pointer rather than the centre: somebody zooming is zooming to
    /// whatever they were doing, and where the pointer was is the best evidence of that.
    @Test("A new zoom is anchored where the pointer was")
    func zoomAnchorsAtThePointer() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var telemetry = InputTelemetry()
        telemetry.pointer = [
            PointerSample(time: 0, position: CGPoint(x: 100, y: 100)),
            PointerSample(time: 4, position: CGPoint(x: 800, y: 400))
        ]
        let studio = try model(in: folder, telemetry: telemetry)
        studio.playhead = 5
        studio.addZoom()

        let cue = try #require(studio.edit.zooms.first)
        #expect(cue.anchor.point(in: studio.manifest.pixelSize) == CGPoint(x: 800, y: 400))
        #expect(studio.selectedZoom == cue.id)
    }

    @Test("A zoom with no pointer track falls back to the centre of the frame")
    func zoomWithoutTelemetry() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.addZoom()
        let cue = try #require(studio.edit.zooms.first)
        #expect(cue.anchor.point(in: studio.manifest.pixelSize) == CGPoint(x: 960, y: 540))
    }

    @Test("A zoom added at the very end still fits inside the recording")
    func zoomAtTheEnd() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder, duration: 5)
        studio.playhead = 5
        studio.addZoom(duration: 3)
        let cue = try #require(studio.edit.zooms.first)
        #expect(cue.end <= 5.001, "the cue runs past the end of the recording")
    }

    /// Run twice should give the same result as run once: appending would stack cues on
    /// top of each other and zoom the viewer into a corner.
    @Test("Smart zooms replace rather than accumulate")
    func smartZoomsAreIdempotent() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var telemetry = InputTelemetry()
        telemetry.clicks = (0 ..< 6).map {
            ClickEvent(time: 1 + Double($0) * 0.3, position: CGPoint(x: 500, y: 500))
        }
        let studio = try model(in: folder, telemetry: telemetry)

        studio.planSmartZooms()
        let first = studio.edit.zooms.count
        #expect(first > 0)
        studio.planSmartZooms()
        #expect(studio.edit.zooms.count == first)
    }

    @Test("Smart zooms with nothing to zoom to say so rather than silently doing nothing")
    func smartZoomsWithNoClicks() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.planSmartZooms()
        #expect(studio.edit.zooms.isEmpty)
        #expect(studio.failure != nil)
    }

    @Test("Removing the selected zoom clears the selection with it")
    func removeZoom() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.addZoom()
        studio.removeSelectedZoom()
        #expect(studio.edit.zooms.isEmpty)
        #expect(studio.selectedZoom == nil)
    }

    @Test("A cue can be changed in place")
    func updateZoom() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.addZoom()
        let id = try #require(studio.selectedZoom)
        studio.updateZoom(id) { $0.magnification = 3 }
        #expect(studio.edit.zooms.first?.magnification == 3)
    }

    /// Undo can remove the cue the inspector is showing, and an inspector bound to a cue
    /// that no longer exists is a crash waiting for the next redraw.
    @Test("Undoing away the selected zoom clears the selection")
    func undoClearsAStaleSelection() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.addZoom()
        #expect(studio.selectedZoom != nil)
        studio.undo()
        #expect(studio.selectedZoom == nil)
    }

    // MARK: - Clips

    @Test("Splitting at the playhead makes two clips")
    func split() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 4
        studio.splitAtPlayhead()
        #expect(studio.edit.clips.clips.count == 2)
    }

    @Test("A split clip can be removed, and the recording gets shorter")
    func removeClip() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 4
        studio.splitAtPlayhead()
        studio.playhead = 1
        studio.removeClipAtPlayhead()
        #expect(studio.edit.clips.clips.count == 1)
        #expect(studio.edit.duration < 10)
    }

    /// A timeline with nothing in it is not an edit, it is a deleted recording — and
    /// deleting a recording is not something a trim button should be able to do.
    @Test("The last clip cannot be removed")
    func lastClipStays() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.removeClipAtPlayhead()
        #expect(studio.edit.clips.clips.count == 1)
        #expect(studio.failure != nil)
    }

    @Test("Speeding a clip up shortens the edit")
    func speedShortens() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.setSpeedAtPlayhead(2)
        #expect(abs(studio.edit.duration - 5) < 0.001)
    }

    @Test("The playhead never survives past the end of a shortened edit")
    func playheadIsClamped() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 9
        studio.setSpeedAtPlayhead(4)
        #expect(studio.playhead <= studio.edit.duration)
    }

    @Test("The playhead cannot be dragged outside the recording")
    func playheadStaysInRange() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = -5
        #expect(studio.playhead == 0)
        studio.playhead = 100
        #expect(studio.playhead == 10)
    }

    // MARK: - Presets

    /// A preset is a look, not an edit. Applying one must never move a cut or a zoom —
    /// somebody trying a style on their finished edit expects to keep the edit.
    @Test("A preset changes the look and leaves the cuts and zooms alone")
    func presetKeepsTheEdit() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 4
        studio.splitAtPlayhead()
        studio.addZoom()
        let clips = studio.edit.clips
        let zooms = studio.edit.zooms

        let preset = try #require(StudioPreset.builtIn.first)
        studio.apply(preset)

        #expect(studio.edit.clips == clips)
        #expect(studio.edit.zooms == zooms)
    }

    // MARK: - Export state

    @Test("An edit that has never been exported is not up to date")
    func exportStateStartsStale() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(!studio.isExportUpToDate)
    }
}
