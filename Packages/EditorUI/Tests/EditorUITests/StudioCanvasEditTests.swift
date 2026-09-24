import Foundation
import StudioSession
import Testing
@testable import EditorUI

@MainActor
@Suite("Studio canvas editing")
struct StudioCanvasEditTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-studio-canvas-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(in folder: URL) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 10,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    @Test("Choosing a canvas colour is one undo step and opens the card")
    func colourFillIsUndoable() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.change { $0.canvas.setBackdropKind(.colour) }
        #expect(studio.edit.canvas.background == .solid(.graphite))
        #expect(studio.edit.canvas.paddingFraction > 0)
        studio.undo()
        #expect(studio.edit.canvas.isIdentity)
    }

    @Test("Importing a wallpaper copies it into the session and opens the card")
    func wallpaperIsCopiedIn() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let source = folder.appendingPathComponent("bg.png")
        try Data("image".utf8).write(to: source)
        studio.importWallpaper(from: source)
        #expect(studio.edit.canvas.background == .wallpaper)
        #expect(studio.edit.canvas.wallpaperFileName?.hasPrefix("wallpaper-") == true)
        #expect(studio.edit.canvas.paddingFraction > 0)
        #expect(studio.session.wallpaperURLs.count == 1)
        studio.removeWallpaper()
        #expect(studio.edit.canvas.wallpaperFileName == nil)
        studio.undo()
        #expect(studio.session.wallpaperURL(for: studio.edit) != nil)
        studio.redo()
        studio.commitOnClose()
        #expect(studio.session.wallpaperURLs.isEmpty)
    }
}
