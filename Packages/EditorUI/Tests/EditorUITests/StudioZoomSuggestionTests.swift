import Foundation
import StudioSession
import Testing
@testable import EditorUI

/// Suggested zooms on the lane, and moving between zooms (docs/09 U3.3).
@MainActor
@Suite("Studio zoom suggestions")
struct StudioZoomSuggestionTests {
    private func studio(clicks: [ClickEvent]) throws -> (StudioDocumentModel, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-zooms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data(repeating: 0, count: 64).write(to: session.screenURL)
        var telemetry = InputTelemetry()
        telemetry.clicks = clicks
        let document = SessionDocument(session: session)
        try document.write(telemetry)
        try document.write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 20,
            hasBakedCursor: true
        ))
        let model = try #require(StudioDocumentModel(session: session))
        model.showsZoomSuggestions = true
        return (model, folder)
    }

    /// Two separate activities: top-left early on, bottom-right later.
    private var twoClusters: [ClickEvent] {
        (0 ..< 3).map { ClickEvent(time: 1 + Double($0) * 0.3, position: CGPoint(x: 300, y: 300)) }
            + (0 ..< 3).map { ClickEvent(time: 10 + Double($0) * 0.3, position: CGPoint(x: 1500, y: 800)) }
    }

    @Test("Each cluster of clicks is a suggestion until something is zoomed there")
    func suggestionsFollowClusters() throws {
        let (model, folder) = try studio(clicks: twoClusters)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(model.zoomSuggestions.count == 2)
        #expect(try model.clickCount(in: #require(model.zoomSuggestions.first)) == 3)

        model.addOrSelectZoom(at: 1.2)
        #expect(model.edit.zooms.count == 1)
        #expect(model.zoomSuggestions.count == 1, "the zoomed cluster no longer suggests itself")
    }

    @Test("Accepting one keeps it and selects it; the others stay suggestions")
    func acceptOne() throws {
        let (model, folder) = try studio(clicks: twoClusters)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try #require(model.zoomSuggestions.first)
        model.acceptZoomSuggestion(first)
        #expect(model.edit.zooms.count == 1)
        #expect(model.selectedZoom == model.edit.zooms.first?.id)
        #expect(model.edit.zooms.first?.id != first.id, "an accepted suggestion gets its own identity")
        #expect(model.zoomSuggestions.count == 1)
        model.undo()
        #expect(model.edit.zooms.isEmpty)
        #expect(model.zoomSuggestions.count == 2)
    }

    @Test("Dismissed suggestions stay hidden until restored")
    func dismiss() throws {
        let (model, folder) = try studio(clicks: twoClusters)
        defer { try? FileManager.default.removeItem(at: folder) }
        try model.dismissZoomSuggestion(#require(model.zoomSuggestions.first))
        #expect(model.zoomSuggestions.count == 1)
        model.addSuggestedZooms()
        #expect(model.edit.zooms.count == 1, "a dismissed suggestion is not added by Add All")
        model.restoreDismissedZoomSuggestions()
        #expect(model.zoomSuggestions.count == 1)
    }

    @Test("Adding all suggestions keeps the zooms placed by hand")
    func addAllKeepsManualZooms() throws {
        let (model, folder) = try studio(clicks: twoClusters)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.addZoom(at: 15)
        let manual = try #require(model.edit.zooms.first?.id)
        model.addSuggestedZooms()
        #expect(model.edit.zooms.count == 3)
        #expect(model.edit.zooms.contains { $0.id == manual })
        #expect(model.zoomSuggestions.isEmpty)
        model.addSuggestedZooms()
        #expect(model.edit.zooms.count == 3, "running it again adds nothing")
    }

    @Test("Hiding suggestions hides them all")
    func hidden() throws {
        let (model, folder) = try studio(clicks: twoClusters)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.showsZoomSuggestions = false
        defer { model.showsZoomSuggestions = true }
        #expect(model.zoomSuggestions.isEmpty)
    }

    @Test("No clicks: nothing to suggest, and Add All says so")
    func noClicks() throws {
        let (model, folder) = try studio(clicks: [])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(model.zoomSuggestions.isEmpty)
        model.addSuggestedZooms()
        #expect(model.failure != nil)
    }

    @Test("Z on an existing zoom selects it instead of stacking another")
    func zSelectsExisting() throws {
        let (model, folder) = try studio(clicks: [])
        defer { try? FileManager.default.removeItem(at: folder) }
        model.addOrSelectZoom(at: 4)
        let id = try #require(model.selectedZoom)
        model.selectedZoom = nil
        model.addOrSelectZoom(at: 5)
        #expect(model.edit.zooms.count == 1)
        #expect(model.selectedZoom == id)
    }

    @Test("[ and ] step through zooms in playing order")
    func stepping() throws {
        let (model, folder) = try studio(clicks: [])
        defer { try? FileManager.default.removeItem(at: folder) }
        model.addZoom(at: 12)
        model.addZoom(at: 2)
        let ordered = model.zoomsInOrder.map(\.id)
        #expect(ordered.count == 2)

        model.selectedZoom = nil
        model.playhead = 0
        model.selectAdjacentZoom(forward: true)
        #expect(model.selectedZoom == ordered[0])
        #expect(abs(model.playhead - 2) < 0.01)
        model.selectAdjacentZoom(forward: true)
        #expect(model.selectedZoom == ordered[1])
        model.selectAdjacentZoom(forward: true)
        #expect(model.selectedZoom == ordered[1], "no zoom after the last")
        model.selectAdjacentZoom(forward: false)
        #expect(model.selectedZoom == ordered[0])
    }
}

@MainActor
@Suite("Studio zoom placement")
struct StudioZoomPlacementTests {
    private func studio() throws -> (StudioDocumentModel, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-place-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data(repeating: 0, count: 64).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 20,
            hasBakedCursor: true
        ))
        return try (#require(StudioDocumentModel(session: session)), folder)
    }

    @Test("A click adds the default zoom exactly where the preview showed it")
    func clickMatchesPreview() throws {
        let (model, folder) = try studio()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preview = try #require(model.zoomPlacement(at: 5))
        #expect(abs(preview.low - 5) < 0.001)
        #expect(abs(preview.high - 9.2) < 0.001)
        model.addOrSelectZoom(at: 5)
        let placed = try model.editedDisplayRange(of: #require(model.edit.zooms.first))
        #expect(abs(placed.lowerBound - preview.low) < 0.01)
        #expect(abs(placed.upperBound - preview.high) < 0.01)
    }

    @Test("Near the end, the zoom shifts back so it still fits")
    func fitsAtTheEnd() throws {
        let (model, folder) = try studio()
        defer { try? FileManager.default.removeItem(at: folder) }
        let span = try #require(model.zoomPlacement(at: 19.5))
        #expect(span.high <= 20.0001)
        #expect(span.high - span.low >= 4.1)
    }

    @Test("A neighbouring zoom stops the new one, and a gap too small offers nothing")
    func neighbours() throws {
        let (model, folder) = try studio()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.addOrSelectZoom(at: 7)
        let first = try model.editedDisplayRange(of: #require(model.edit.zooms.first))

        let before = try #require(model.zoomPlacement(at: 5))
        #expect(before.high <= first.lowerBound + 0.001)
        #expect(model.zoomPlacement(at: first.lowerBound - 0.5) == nil, "half a second is no room")
        #expect(model.zoomPlacement(at: first.lowerBound + 1) == nil, "inside a zoom is no room")

        model.selectedZoom = nil
        model.addOrSelectZoom(at: first.lowerBound + 1)
        #expect(model.edit.zooms.count == 1, "clicking a zoom selects it rather than stacking")
        #expect(model.selectedZoom != nil)

        model.addOrSelectZoom(at: first.lowerBound - 0.5)
        #expect(model.edit.zooms.count == 1)
        #expect(model.notice != nil, "no room says so")
    }
}
