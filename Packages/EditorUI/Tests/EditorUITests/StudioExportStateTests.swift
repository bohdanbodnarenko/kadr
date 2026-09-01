import AppKit
import Foundation
import StudioRender
import StudioSession
import Testing
@testable import EditorUI

/// What a finished export leaves behind, and what it lets the next one skip (docs/11 S2).
///
/// `RenderStamp` had both halves written and tested and no production caller at all, so
/// "do not re-render an unchanged edit" existed only in the type system: pressing Export
/// twice on a ten-minute recording rendered it twice.
@MainActor
@Suite("Studio export state")
struct StudioExportStateTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-export-\(UUID().uuidString)", isDirectory: true)
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

    @Test("An edit that has never been exported has no render stamp")
    func exportStateStartsStale() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        #expect(SessionDocument(session: studio.session).renderStamp() == nil)
    }

    /// The stamp is read, not just written (docs/11 S2). Both halves of the cache existed
    /// and had zero production callers, so pressing Export twice re-rendered in full.
    @Test("Exporting an edit that was already exported reuses the finished file")
    func exportReusesAFinishedRender() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        // A finished render of exactly this edit, stamped the way `export` stamps one.
        let rendered = folder.appendingPathComponent("already.mov")
        try Data("a finished export".utf8).write(to: rendered)
        let digest = try #require(RenderStamp.digest(of: studio.edit))
        let size = StudioRenderPlan(edit: studio.edit, sourceSize: studio.manifest.pixelSize).outputSize
        try SessionDocument(session: studio.session).write(RenderStamp(
            editDigest: digest,
            outputPath: rendered.path,
            pixelSize: size
        ))

        let destination = folder.appendingPathComponent("out.mov")
        await studio.export(to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: destination) == Data("a finished export".utf8))
        #expect(studio.notice != nil, "the user was not told why that was instant")
    }

    /// And a *different* edit is not a hit, which is the half that would ship the wrong
    /// file if it were wrong.
    @Test("Changing the edit invalidates the finished render")
    func changingTheEditIsNotAHit() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        let rendered = folder.appendingPathComponent("already.mov")
        try Data("a finished export".utf8).write(to: rendered)
        let digest = try #require(RenderStamp.digest(of: studio.edit))
        let size = StudioRenderPlan(edit: studio.edit, sourceSize: studio.manifest.pixelSize).outputSize
        let stamp = RenderStamp(editDigest: digest, outputPath: rendered.path, pixelSize: size)

        studio.change { $0.showsClicks.toggle() }
        let changed = try #require(RenderStamp.digest(of: studio.edit))
        #expect(!stamp.matches(editDigest: changed, pixelSize: size))
    }

    @Test("Copy puts the original recording on the clipboard as a file")
    func copyOriginalPutsTheFileOnTheClipboard() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.copyOriginalToClipboard()
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.map(\.standardizedFileURL).contains(studio.session.screenURL.standardizedFileURL) == true)
    }
}
