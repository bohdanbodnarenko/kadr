import AnnotationModel
import CoreGraphics
import Foundation
import MediaExport
import SettingsKit
import Testing
@testable import Kadr

@MainActor
@Suite("Capture project sibling")
struct CaptureProjectTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-project-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A beautify spec is written next to the flattened PNG")
    func writeCreatesSibling() throws {
        let folder = scratch()
        let png = folder.appendingPathComponent("Shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)

        CaptureProject.write(original: makeCapture(), beautify: .cleanWhite, alongside: png)

        let project = CaptureProject.url(alongside: png)
        #expect(FileManager.default.fileExists(atPath: project.path))
        let contents = try KadrDocumentFile.read(from: project)
        #expect(contents.document.beautify == .cleanWhite)
        #expect(contents.document.baseImage.size == CGSize(width: 10, height: 5))
        #expect(CaptureProject.editorURL(for: png) == project)
    }

    @Test("Without a project the editor opens the image itself")
    func missingProjectOpensImage() {
        let png = scratch().appendingPathComponent("Bare.png")
        #expect(CaptureProject.editorURL(for: png) == png)
    }

    @Test("Finalising a staged capture keeps the project next to it")
    func moveKeepsSibling() throws {
        let folder = scratch()
        let sourcePNG = folder.appendingPathComponent("Staged.png")
        let destPNG = folder.appendingPathComponent("Final.png")
        try Data().write(to: sourcePNG)
        CaptureProject.write(original: makeCapture(), beautify: .twitter, alongside: sourcePNG)

        CaptureProject.move(from: sourcePNG, to: destPNG)

        #expect(FileManager.default.fileExists(atPath: CaptureProject.url(alongside: sourcePNG).path) == false)
        let moved = CaptureProject.url(alongside: destPNG)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(try KadrDocumentFile.read(from: moved).document.beautify == .twitter)
    }

    @Test("Trashing a capture also trashes its project")
    func trashRemovesSibling() throws {
        let folder = scratch()
        let png = folder.appendingPathComponent("Gone.png")
        try Data().write(to: png)
        CaptureProject.write(original: makeCapture(), beautify: .instagram, alongside: png)
        let project = CaptureProject.url(alongside: png)
        #expect(FileManager.default.fileExists(atPath: project.path))

        CaptureProject.trash(alongside: png)

        #expect(FileManager.default.fileExists(atPath: project.path) == false)
    }
}

@MainActor
@Suite("Auto-beautify presets")
struct AutoBeautifyTests {
    @Test("Off writes nothing; each built-in maps onto its editor spec", arguments: [
        (AutoBeautifyPreset.off, nil as BeautifySpec?),
        (.cleanWhite, BeautifySpec.cleanWhite),
        (.twitter, .twitter),
        (.instagram, .instagram),
        (.story, .story),
        (.stuckBottom, .stuckBottom)
    ])
    func mapsOntoEditorSpec(pair: (AutoBeautifyPreset, BeautifySpec?)) {
        #expect(AutoBeautify.spec(for: pair.0) == pair.1)
    }
}

@MainActor
@Suite("Menu-bar drop")
struct StatusItemDropTests {
    @Test("Images and projects are accepted; recordings are not", arguments: [
        ("shot.png", true),
        ("shot.jpg", true),
        ("shot.jpeg", true),
        ("shot.heic", true),
        ("shot.webp", true),
        ("shot.kadr", true),
        ("Shot.KADR", true),
        ("clip.mov", false),
        ("clip.mp4", false),
        ("notes.txt", false),
        ("archive.zip", false)
    ])
    func acceptsStillFiles(pair: (String, Bool)) {
        let url = URL(fileURLWithPath: "/tmp/\(pair.0)")
        #expect(StatusItemDropView.accepts(url) == pair.1)
    }
}

@MainActor
@Suite("Window backdrop as editor chrome")
struct WindowBackdropBeautifyTests {
    @Test("A transparent window has no beautify chrome")
    func transparentHasNoSpec() {
        let settings = AppSettings(store: throwawayDefaults())
        #expect(settings.transparentWindowBackground)
        #expect(WindowBackdropApplier.beautifySpec(settings: settings, displayID: nil) == nil)
    }

    @Test("An opaque fill becomes padding-only beautify chrome")
    func opaqueFillBecomesBeautify() {
        let settings = AppSettings(store: throwawayDefaults())
        settings.transparentWindowBackground = false
        settings.windowBackdrop = .white
        settings.windowBackdropPadding = 48
        let spec = WindowBackdropApplier.beautifySpec(settings: settings, displayID: nil)
        #expect(spec?.padding == .points(48))
        #expect(spec?.backdrop == .solid(.white))
        #expect(spec?.shadow == BeautifyShadow.none)
        #expect(spec?.aspect == .original)
    }
}

@MainActor
@Suite("Quick Access keeps the project")
struct CaptureProjectQuickAccessTests {
    @Test("Finalising a staged capture moves its editable project too")
    func finalizeMovesProject() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.defaultAction = .overlayOnly

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        let stagedURL = try #require(result.fileURL)
        CaptureProject.write(original: capture, beautify: .cleanWhite, alongside: stagedURL)
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)

        harness.manager.copy(item)

        let saved = try #require(harness.manager.items.first?.fileURL)
        #expect(FileManager.default.fileExists(atPath: CaptureProject.url(alongside: stagedURL).path) == false)
        #expect(FileManager.default.fileExists(atPath: CaptureProject.url(alongside: saved).path))
        harness.manager.dismissAll()
    }

    @Test("Deleting a capture trashes its editable project")
    func deleteTrashesProject() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))
        harness.settings.defaultAction = .saveToFolder

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        let url = try #require(result.fileURL)
        CaptureProject.write(original: capture, beautify: .story, alongside: url)
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)
        let project = CaptureProject.url(alongside: item.fileURL)
        #expect(FileManager.default.fileExists(atPath: project.path))

        harness.manager.delete(item)

        #expect(FileManager.default.fileExists(atPath: project.path) == false)
    }
}
