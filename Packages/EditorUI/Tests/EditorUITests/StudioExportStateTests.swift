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
            pixelSize: size,
            inputsDigest: studio.exportSnapshot().inputsDigest
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

    @Test("Copy Original puts the source recording on the clipboard as a file")
    func copyOriginalPutsTheFileOnTheClipboard() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.copyOriginalToClipboard()
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.map(\.standardizedFileURL).contains(studio.session.screenURL.standardizedFileURL) == true)
    }

    @Test("Copy reuses a stamped render without re-exporting")
    func copyEditedReusesStampedRender() async throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        let rendered = folder.appendingPathComponent("already.mov")
        try Data("edited export".utf8).write(to: rendered)
        let digest = try #require(RenderStamp.digest(of: studio.edit))
        let size = StudioRenderPlan(edit: studio.edit, sourceSize: studio.manifest.pixelSize).outputSize
        try SessionDocument(session: studio.session).write(RenderStamp(
            editDigest: digest,
            outputPath: rendered.path,
            pixelSize: size,
            inputsDigest: studio.exportSnapshot().inputsDigest
        ))

        await studio.copyEditedToClipboard()
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.isEmpty == false)
        #expect(studio.notice?.contains("Copied") == true)
    }

    // MARK: - docs/17 T-STU-1: what else a render depends on

    private func stampFinishedRender(for studio: StudioDocumentModel, in folder: URL) throws {
        let rendered = folder.appendingPathComponent("already.mov")
        try Data("a finished export".utf8).write(to: rendered)
        let snapshot = studio.exportSnapshot()
        try SessionDocument(session: studio.session).write(RenderStamp(
            editDigest: #require(RenderStamp.digest(of: snapshot.edit)),
            outputPath: rendered.path,
            pixelSize: StudioRenderPlan(edit: snapshot.edit, sourceSize: studio.manifest.pixelSize).outputSize,
            settingsDigest: RenderStamp.digest(of: snapshot.settings),
            inputsDigest: snapshot.inputsDigest
        ))
    }

    @Test("A stamp from before inputs were recorded is not reused")
    func legacyStampIsStale() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let digest = try #require(RenderStamp.digest(of: studio.edit))
        let size = StudioRenderPlan(edit: studio.edit, sourceSize: studio.manifest.pixelSize).outputSize
        let rendered = folder.appendingPathComponent("already.mov")
        try Data("old build".utf8).write(to: rendered)
        let legacy = RenderStamp(editDigest: digest, outputPath: rendered.path, pixelSize: size)
        let inputs = try #require(studio.exportSnapshot().inputsDigest)
        #expect(!legacy.matches(editDigest: digest, pixelSize: size, inputsDigest: inputs))
    }

    @Test("A new transcript changes the render inputs")
    func transcriptChangesTheInputs() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let before = studio.renderInputsDigest(edit: studio.edit, transcript: nil)
        let words = Transcript(words: [.init(text: "hello", start: 0, end: 0.5)])
        let after = studio.renderInputsDigest(edit: studio.edit, transcript: words)
        #expect(before != nil)
        #expect(before != after)
    }

    @Test("Swapping the wallpaper file changes the edit, so the stamp misses")
    func wallpaperSwapIsAMiss() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        let first = folder.appendingPathComponent("a.png")
        let second = folder.appendingPathComponent("b.png")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        studio.importWallpaper(from: first)
        try stampFinishedRender(for: studio, in: folder)
        let stamp = try #require(SessionDocument(session: studio.session).renderStamp())

        studio.importWallpaper(from: second)
        let snapshot = studio.exportSnapshot()
        let digest = try #require(RenderStamp.digest(of: snapshot.edit))
        #expect(!stamp.matches(
            editDigest: digest,
            pixelSize: stamp.pixelSize,
            settingsDigest: RenderStamp.digest(of: snapshot.settings),
            inputsDigest: snapshot.inputsDigest
        ))
    }

    // MARK: - docs/17 T-STU-2: editing while an export runs

    /// Through a real render: the edit changes while the movie is being written, and the
    /// stamp must still describe the movie, not the edit on screen.
    @Test("Editing during an export stamps the edit that was exported")
    func editDuringExportStampsTheSnapshot() async throws {
        let folder = StudioPlaybackFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try await StudioPlaybackFixtures.model(in: folder, seconds: 4)
        let exported = try #require(RenderStamp.digest(of: studio.edit))
        let destination = folder.appendingPathComponent("out.mov")

        let export = Task { await studio.export(to: destination) }
        try await StudioPlaybackFixtures.wait { studio.exportProgress != nil }
        studio.change { $0.showsClicks.toggle() }
        #expect(studio.isExporting, "the edit landed after the render, so this proves nothing")
        let edited = try #require(RenderStamp.digest(of: studio.edit))
        await export.value

        let stamp = try #require(SessionDocument(session: studio.session).renderStamp())
        #expect(stamp.editDigest == exported)
        #expect(stamp.editDigest != edited)
    }

    // MARK: - docs/17 T-STU-4: Copy and Share are tracked renders

    @Test("Copy renders into a per-session staging folder, named for the project, removed on close")
    func copyIsStagedAndPurged() async throws {
        let folder = StudioPlaybackFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try await StudioPlaybackFixtures.model(in: folder, seconds: 1)
        try studio.session.setDisplayName("Demo: take 2")

        await studio.copyEditedToClipboard()
        let staged = try studio.stagedRenderURL()
        #expect(staged.deletingPathExtension().lastPathComponent == "Demo- take 2")
        #expect(FileManager.default.fileExists(atPath: staged.path))

        studio.commitOnClose()
        #expect(!FileManager.default.fileExists(atPath: studio.stagingDirectory.path))
    }

    @Test("Copy counts as an export, and Cancel stops it")
    func copyIsCancellable() async throws {
        let folder = StudioPlaybackFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try await StudioPlaybackFixtures.model(in: folder, seconds: 4)
        NSPasteboard.general.clearContents()

        let copy = Task { await studio.copyEditedToClipboard() }
        try await StudioPlaybackFixtures.wait { studio.isExporting }
        #expect(studio.isExporting, "the close and quit guards read this")
        await studio.cancelExport()
        await copy.value

        #expect(!studio.isExporting)
        #expect(studio.failure == nil)
        #expect(studio.notice?.contains("Copied") != true)
    }

    @Test("File names drop path separators", arguments: [
        ("Demo", "Demo"),
        ("a/b:c", "a-b-c"),
        ("  ..  ", "Recording"),
        ("", "Recording")
    ])
    func safeFileNames(input: String, expected: String) {
        #expect(StudioDocumentModel.safeFileName(input) == expected)
    }
}
