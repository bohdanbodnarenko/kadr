import Foundation
import StudioSession
import Testing
@testable import EditorUI

@MainActor
@Suite("Studio camera and zoom aiming")
struct StudioCameraEditTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-studio-camera-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(
        in folder: URL,
        duration: TimeInterval = 10,
        telemetry: InputTelemetry = InputTelemetry()
    ) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        let document = SessionDocument(session: session)
        try document.write(telemetry)
        try document.write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: duration,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    @Test("A dragged range on the zoom lane becomes a cue")
    func draggedZoomFillsTheRange() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.addZoom(from: 1, to: 4)
        let cue = try #require(studio.edit.zooms.first)
        #expect(abs(cue.start - 1) < 0.001)
        #expect(abs(cue.end - 4) < 0.001)
        #expect(studio.selectedZoom == cue.id)
    }

    @Test("A short drag on the zoom lane does not create a zoom")
    func shortDragDoesNotCreateAZoom() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.addZoom(from: 2, to: 2.1)
        #expect(studio.edit.zooms.isEmpty)
    }

    @Test("A dragged zoom stops at an existing cue")
    func draggedZoomStopsAtNeighbour() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.addZoom(from: 5, to: 8)
        studio.addZoom(from: 1, to: 9)
        #expect(studio.edit.zooms.count == 2)
        let later = try #require(studio.edit.zooms.first { $0.start < 4 })
        #expect(later.end <= studio.edit.zooms.first { $0.start >= 4 }?.start ?? 0)
    }

    @Test("Resizing a zoom from its ends changes the occupied range")
    func resizeZoomRange() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.addZoom(from: 2, to: 5)
        let id = try #require(studio.selectedZoom)
        studio.setZoomRange(id, start: 1, end: 6)
        let cue = try #require(studio.edit.zooms.first)
        #expect(abs(cue.start - 1) < 0.001)
        #expect(abs(cue.end - 6) < 0.001)
    }

    @Test("Aiming a zoom at the pointer uses the sample at the playhead")
    func aimZoomAtPointer() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var telemetry = InputTelemetry()
        telemetry.pointer = [PointerSample(time: 1, position: CGPoint(x: 100, y: 200))]
        let studio = try model(in: folder, telemetry: telemetry)
        studio.addZoom()
        studio.playhead = 1
        studio.aimSelectedZoomAtPointer()
        let cue = try #require(studio.edit.zooms.first)
        #expect(cue.anchor.point(in: studio.manifest.pixelSize) == CGPoint(x: 100, y: 200))
    }

    @Test("Click ticks on the zoom lane are the downs, not the ups")
    func clickTimesArePresses() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var telemetry = InputTelemetry()
        telemetry.clicks = [
            ClickEvent(time: 1, position: .zero, isDown: true),
            ClickEvent(time: 1.1, position: .zero, isDown: false),
            ClickEvent(time: 2, position: .zero, isDown: true)
        ]
        let studio = try model(in: folder, telemetry: telemetry)
        #expect(studio.editedClickTimes == [1, 2])
    }

    @Test("Aiming a zoom writes a fixed pixel target")
    func zoomAnchorFromPad() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.addZoom()
        let id = try #require(studio.selectedZoom)
        studio.setZoomAnchor(id, toNormalized: CGPoint(x: 0.25, y: 0.75))
        #expect(studio.normalizedZoomAnchor(for: id).x == 0.25)
        #expect(studio.normalizedZoomAnchor(for: id).y == 0.75)
        let cue = try #require(studio.edit.zooms.first)
        #expect(cue.anchor.point(in: studio.manifest.pixelSize) == CGPoint(x: 480, y: 810))
    }

    @Test("Pointer focus follows the pointer; Fixed snapshots it")
    func zoomFocusPointerThenFixed() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var telemetry = InputTelemetry()
        telemetry.pointer = [PointerSample(time: 1, position: CGPoint(x: 100, y: 200))]
        let studio = try model(in: folder, telemetry: telemetry)
        studio.addZoom()
        let id = try #require(studio.selectedZoom)
        #expect(studio.zoomFocus(of: id) == .fixed)
        studio.playhead = 1
        studio.setZoomFocus(id, to: .pointer)
        #expect(studio.edit.zooms.first?.anchor == .pointer)
        #expect(studio.edit.zooms.first?.boundsBias == ZoomCue.defaultPointerBoundsBias)
        studio.setZoomFocus(id, to: .fixed)
        let cue = try #require(studio.edit.zooms.first)
        #expect(cue.anchor == .fixed(CGPoint(x: 100, y: 200)))
        studio.setZoomFocus(id, to: .centre)
        #expect(studio.edit.zooms.first?.anchor == .centre)
    }

    @Test("A zoom can be switched off without deleting it")
    func zoomCanBeDisabled() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.addZoom()
        let id = try #require(studio.selectedZoom)
        studio.updateZoom(id) { $0.isEnabled = false }
        #expect(studio.edit.zooms.first?.isEnabled == false)
        studio.change { $0.showsZooms = false }
        #expect(!studio.edit.showsZooms)
        #expect(studio.edit.zooms.count == 1)
    }

    @Test("Trash prefers a selected zoom over the clip under the playhead")
    func deleteTimelineSelectionPrefersZoom() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 4
        studio.splitAtPlayhead()
        studio.addZoom()
        #expect(studio.edit.zooms.count == 1)
        #expect(studio.edit.clips.clips.count == 2)
        studio.deleteTimelineSelection()
        #expect(studio.edit.zooms.isEmpty)
        #expect(studio.edit.clips.clips.count == 2)
    }

    @Test("Resetting zooms clears the cues and leaves the clips")
    func resetZoomsLeavesClips() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.playhead = 4
        studio.splitAtPlayhead()
        studio.addZoom()
        studio.resetZooms()
        #expect(studio.edit.zooms.isEmpty)
        #expect(studio.edit.clips.clips.count == 2)
        #expect(studio.hasClipEdits)
    }

    @Test("Dragging the camera writes a free position; snapping forgets it")
    func cameraDragThenSnap() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.moveCamera(toNormalizedCenter: CGPoint(x: 0.3, y: 0.4))
        #expect(studio.edit.camera.center != nil)
        studio.snapCamera(to: .topLeading)
        #expect(studio.edit.camera.center == nil)
        #expect(studio.edit.camera.placement == .topLeading)
    }

    @Test("Resizing the camera from a corner keeps the opposite edge still")
    func cameraResizePinsOppositeCorner() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.moveCamera(toNormalizedCenter: CGPoint(x: 0.4, y: 0.4))
        let before = studio.edit.camera.frame(in: studio.manifest.pixelSize)
        studio.resizeCamera(
            toSizeFraction: 0.35,
            pinningTopLeading: CGPoint(x: before.minX, y: before.minY)
        )
        let after = studio.edit.camera.frame(in: studio.manifest.pixelSize)
        #expect(abs(after.minX - before.minX) < 1)
        #expect(abs(after.minY - before.minY) < 1)
        #expect(abs(studio.edit.camera.sizeFraction - 0.35) < 0.001)
    }
}
