import Foundation
import StudioSession
import Testing
@testable import EditorUI

@MainActor
@Suite("Studio style presets")
struct StudioStylePresetTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-studio-presets-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func throwawayStore() -> StudioPresetStore {
        let suite = UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not open a throwaway defaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return StudioPresetStore(store: defaults)
    }

    private func model(in folder: URL, store: StudioPresetStore) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 8,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session, presetStore: store))
    }

    @Test("Saving a look and applying it restores the canvas")
    func saveAndApply() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = throwawayStore()
        let studio = try model(in: folder, store: store)
        studio.change { $0.canvas = .presenter }
        studio.saveCurrentPreset(named: "My presenter")
        #expect(studio.userPresets.map(\.name) == ["My presenter"])

        studio.change { $0.canvas = .identity }
        let saved = try #require(studio.userPresets.first)
        studio.applyPreset(saved)
        #expect(studio.edit.canvas == .presenter)
        #expect(!studio.isAppliedPresetEdited)
    }

    @Test("Saving over a name replaces it rather than stacking")
    func savingReplacesTheName() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = throwawayStore()
        let studio = try model(in: folder, store: store)
        studio.change { $0.canvas = .presenter }
        studio.saveCurrentPreset(named: "Look")
        studio.change { $0.canvas = .paper }
        studio.saveCurrentPreset(named: "Look")
        #expect(studio.userPresets.count == 1)
        #expect(studio.userPresets.first?.canvas == .paper)
    }

    @Test("A default look is applied only to a recording that has never been edited")
    func defaultAppliesWhenFresh() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = throwawayStore()
        let first = try model(in: folder, store: store)
        first.change { $0.canvas = .presenter }
        first.saveCurrentPreset(named: "Presenter")
        let id = try #require(first.userPresets.first?.id)
        first.setDefaultPreset(id: id)

        let other = scratch()
        defer { try? FileManager.default.removeItem(at: other) }
        let fresh = try model(in: other, store: store)
        fresh.applyDefaultPresetIfFresh()
        #expect(fresh.edit.canvas == .presenter)
        #expect(!fresh.canUndo)

        fresh.change { $0.canvas = .paper }
        try SessionDocument(session: fresh.session).writeDraft(fresh.edit)
        let reopened = try #require(StudioDocumentModel(session: fresh.session, presetStore: store))
        reopened.applyDefaultPresetIfFresh()
        #expect(reopened.edit.canvas == .paper, "a draft was overwritten by the default look")
    }

    @Test("A fresh recording without a chosen default opens as Presenter")
    func presenterIsTheFallbackLook() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder, store: throwawayStore())
        studio.applyDefaultPresetIfFresh()
        #expect(studio.edit.canvas == .presenter)
        #expect(studio.appliedPresetName == "Presenter")
        #expect(!studio.canUndo)
    }

    @Test("A fresh recording with click clusters opens with smart zooms")
    func freshSessionGetsSmartZooms() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var telemetry = InputTelemetry()
        telemetry.clicks = (0 ..< 6).map {
            ClickEvent(time: 1 + Double($0) * 0.3, position: CGPoint(x: 500, y: 500))
        }
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 8,
            hasBakedCursor: true
        ))
        try SessionDocument(session: session).write(telemetry)
        let studio = try #require(StudioDocumentModel(session: session, presetStore: throwawayStore()))
        studio.applyDefaultPresetIfFresh()
        #expect(!studio.edit.zooms.isEmpty)
        #expect(!studio.canUndo)
    }

    @Test("Deleting the applied look forgets it was on")
    func deleteClearsApplied() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = throwawayStore()
        let studio = try model(in: folder, store: store)
        studio.change { $0.canvas = .presenter }
        studio.saveCurrentPreset(named: "Gone")
        let id = try #require(studio.appliedPresetID)
        studio.deletePreset(id: id)
        #expect(studio.appliedPresetID == nil)
        #expect(studio.edit.canvas == .presenter)
    }
}
