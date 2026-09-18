import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// Resizing a zoom from the lane (docs/09 U3.3).
@MainActor
@Suite("Studio zoom resize")
struct StudioZoomResizeTests {
    private func studio() throws -> (StudioDocumentModel, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-resize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data(repeating: 0, count: 64).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 30,
            hasBakedCursor: true
        ))
        return try (#require(StudioDocumentModel(session: session)), folder)
    }

    @Test("Shrinking and growing in one drag gives the original moves back")
    func transitionIsNotRatcheted() throws {
        let (model, folder) = try studio()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.addZoom(at: 5)
        let cue = try #require(model.edit.zooms.first)
        let original = cue.transitionDuration
        let span = model.editedDisplayRange(of: cue)

        // The drag squeezes the cue to a sliver, then lets it out again.
        model.setZoomRange(cue.id, start: span.lowerBound, end: span.lowerBound + 0.6, preferredTransition: original)
        #expect(try #require(model.edit.zooms.first).transitionDuration < original)
        model.setZoomRange(cue.id, start: span.lowerBound, end: span.upperBound, preferredTransition: original)
        #expect(try #require(model.edit.zooms.first).transitionDuration == original)

        let restored = try model.editedDisplayRange(of: #require(model.edit.zooms.first))
        #expect(abs(restored.lowerBound - span.lowerBound) < 0.001)
        #expect(abs(restored.upperBound - span.upperBound) < 0.001)
    }

    @Test("The same drag in many small steps is one undo step")
    func resizeIsOneUndoStep() throws {
        let (model, folder) = try studio()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.addZoom(at: 5)
        let cue = try #require(model.edit.zooms.first)
        let span = model.editedDisplayRange(of: cue)
        for step in 1 ... 20 {
            model.setZoomRange(cue.id, start: span.lowerBound, end: span.upperBound + Double(step) * 0.05)
        }
        model.undo()
        let after = try model.editedDisplayRange(of: #require(model.edit.zooms.first))
        #expect(abs(after.upperBound - span.upperBound) < 0.001)
    }
}
