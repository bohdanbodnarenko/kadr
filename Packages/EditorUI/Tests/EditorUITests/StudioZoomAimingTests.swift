import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// Aiming a zoom on the picture (docs/09 U3.3).
///
/// The timeline says when a zoom happens; these cover the half that used to be invisible —
/// where it points, where that default came from, and the mode that shows it.
@MainActor
@Suite("Studio zoom aiming")
struct StudioZoomAimingTests {
    private func studio(pointer: [PointerSample] = []) throws -> (StudioDocumentModel, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-aim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data(repeating: 0, count: 64).write(to: session.screenURL)
        var telemetry = InputTelemetry()
        telemetry.pointer = pointer
        let document = SessionDocument(session: session)
        try document.write(telemetry)
        try document.write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 20,
            hasBakedCursor: true
        ))
        return try (#require(StudioDocumentModel(session: session)), folder)
    }

    /// A zoom to the middle of the screen is almost never what anyone means; the pointer
    /// is the best evidence of what they were doing.
    @Test("A zoom added by hand aims where the pointer was")
    func addedZoomAimsAtThePointer() throws {
        let (model, folder) = try studio(pointer: [
            PointerSample(time: 0, position: CGPoint(x: 100, y: 100)),
            PointerSample(time: 4.9, position: CGPoint(x: 1500, y: 800))
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        model.addZoom(at: 5)

        let cue = try #require(model.edit.zooms.first)
        #expect(cue.anchor.point(in: model.manifest.pixelSize) == CGPoint(x: 1500, y: 800))
        #expect(model.pointerPixel(forZoom: cue.id) == CGPoint(x: 1500, y: 800))
    }

    @Test("Adding one by hand opens the target on the preview")
    func addingOpensAimMode() throws {
        let (model, folder) = try studio(pointer: [PointerSample(time: 0, position: CGPoint(x: 400, y: 400))])
        defer { try? FileManager.default.removeItem(at: folder) }

        model.addZoom(at: 2)

        let cue = try #require(model.edit.zooms.first)
        #expect(model.aimingZoom == cue.id, "the question a new zoom raises is where it points")
        #expect(model.isAimingZoom)

        model.endAimingZoom()
        #expect(!model.isAimingZoom)
    }

    @Test("A pointer-following zoom has no target to place")
    func pointerFollowingHasNothingToAim() throws {
        let (model, folder) = try studio()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.addZoom(at: 2)
        let id = try #require(model.edit.zooms.first?.id)
        model.endAimingZoom()

        model.setZoomFocus(id, to: .pointer)
        model.beginAimingZoom(id)

        #expect(!model.isAimingZoom, "there is no fixed target to drag when the camera chases the pointer")
    }

    @Test("Aiming somewhere is choosing Fixed")
    func aimingMakesItFixed() throws {
        let (model, folder) = try studio()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.addZoom(at: 2)
        let id = try #require(model.edit.zooms.first?.id)
        model.setZoomFocus(id, to: .centre)
        #expect(model.zoomFocus(of: id) == .centre)

        model.aimZoom(id, atNormalized: CGPoint(x: 0.25, y: 0.75))

        #expect(model.zoomFocus(of: id) == .fixed)
        let anchor = model.normalizedZoomAnchor(for: id)
        #expect(abs(anchor.x - 0.25) < 0.001)
        #expect(abs(anchor.y - 0.75) < 0.001)
    }

    /// Drawing the target over an already-zoomed picture would be a rectangle inside itself.
    @Test("The preview drops the zooms while one is being aimed")
    func aimingShowsTheUnzoomedPicture() throws {
        let (model, folder) = try studio()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.addZoom(at: 2)
        #expect(!model.edit.zooms.isEmpty)

        let aiming = StudioPreviewRequest(
            edit: model.edit,
            transcript: nil,
            longestEdge: 1280,
            isCropping: false,
            isAimingZoom: true
        )
        let playing = StudioPreviewRequest(
            edit: model.edit,
            transcript: nil,
            longestEdge: 1280,
            isCropping: false,
            isAimingZoom: false
        )

        #expect(aiming.edit.zooms.isEmpty)
        #expect(playing.edit.zooms.count == model.edit.zooms.count)
        // The edit itself is untouched: aiming is a mode, not a change to the recording.
        #expect(!model.edit.zooms.isEmpty)
    }

    @Test("With no pointer track there is nothing to mark, and the zoom centres")
    func noTelemetryFallsBackToTheCentre() throws {
        let (model, folder) = try studio()
        defer { try? FileManager.default.removeItem(at: folder) }

        model.addZoom(at: 3)

        let cue = try #require(model.edit.zooms.first)
        #expect(model.pointerPixel(forZoom: cue.id) == nil)
        #expect(!model.hasPointerAtPlayhead)
        let anchor = model.normalizedZoomAnchor(for: cue.id)
        #expect(abs(anchor.x - 0.5) < 0.001)
        #expect(abs(anchor.y - 0.5) < 0.001)
    }
}
