import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// Zooms planned from clicks when a recording first opens (docs/18 STU-14).
@MainActor
@Suite("Automatic zooms")
struct StudioAutomaticZoomTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-autozoom-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModel(in folder: URL, telemetry: InputTelemetry) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data(repeating: 0, count: 64).write(to: session.screenURL)
        let document = SessionDocument(session: session)
        try document.write(telemetry)
        try document.write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            scale: 2,
            frameRate: 60,
            duration: 10,
            hasBakedCursor: true,
            hasCamera: false
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    /// docs/18 STU-14: automatic zooms are announced and can be removed in one step.
    @Test("Zooms added from clicks are announced, and Remove takes them back undoably")
    func automaticZoomsAreAnnounced() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var telemetry = InputTelemetry()
        telemetry.clicks = (0 ..< 4).flatMap { index -> [ClickEvent] in
            let time = 3 + Double(index) * 0.4
            let point = CGPoint(x: 400, y: 300)
            return [
                ClickEvent(time: time, position: point, isDown: true),
                ClickEvent(time: time + 0.1, position: point, isDown: false)
            ]
        }
        let studio = try makeModel(in: folder, telemetry: telemetry)
        studio.applyDefaultPresetIfFresh()
        try #require(!studio.edit.zooms.isEmpty, "the fixture's clicks should plan a zoom")
        #expect(studio.notice?.contains("where you clicked") == true)
        #expect(studio.noticeAction == .removeAutomaticZooms)

        studio.performNoticeAction(.removeAutomaticZooms)
        #expect(studio.edit.zooms.isEmpty)
        #expect(studio.notice == nil)
        studio.undo()
        #expect(!studio.edit.zooms.isEmpty)
    }
}
