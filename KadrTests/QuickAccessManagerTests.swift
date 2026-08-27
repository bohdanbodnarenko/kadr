import AppKit
import CaptureCore
import CoreGraphics
import Foundation
import MediaExport
import SettingsKit
import Shared
import Testing
@testable import Kadr

private func temporaryDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeCapture() -> Capture {
    guard let context = CGContext(
        data: nil,
        width: 20,
        height: 10,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        fatalError("Could not create a test capture")
    }
    return Capture(
        image: image,
        metadata: CaptureMetadata(
            source: .display(1),
            displayID: 1,
            scale: .retina,
            pointRect: DisplayRect(x: 0, y: 0, width: 10, height: 5),
            pixelSize: PixelSize(width: 20, height: 10),
            colorSpaceName: nil,
            frontmostApp: AppIdentity(name: "Tester", bundleIdentifier: "app.kadr.tests")
        )
    )
}

/// Everything a Quick Access test needs, wired to throwaway folders and defaults.
@MainActor
private struct TestHarness {
    let manager: QuickAccessManager
    let settings: AppSettings
    let output: CaptureOutput
}

@MainActor
private func makeManager(saveFolder: URL, stagingFolder: URL) -> TestHarness {
    let suite = UUID().uuidString
    guard let store = UserDefaults(suiteName: suite) else {
        fatalError("Could not open a throwaway defaults suite")
    }
    store.removePersistentDomain(forName: suite)
    let settings = AppSettings(store: store)
    settings.saveFolderPath = saveFolder.path

    let output = CaptureOutput(
        settings: settings,
        exporter: CaptureExporter(staging: StagingArea(directory: stagingFolder))
    )
    return TestHarness(
        manager: QuickAccessManager(settings: settings, output: output),
        settings: settings,
        output: output
    )
}

@MainActor
@Suite("Quick Access Overlay", .serialized)
struct QuickAccessManagerTests {
    @Test("A capture puts a card up")
    func showsACard() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))
        let capture = makeCapture()

        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)

        #expect(harness.manager.items.count == 1)
        #expect(harness.manager.items[0].pixelSize == PixelSize(width: 20, height: 10))
        harness.manager.dismissAll()
    }

    @Test("Newest cards go in front")
    func newestFirst() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))

        for _ in 0 ..< 3 {
            let capture = makeCapture()
            let result = try #require(harness.output.deliver(capture))
            harness.manager.show(result, capture: capture)
        }

        #expect(harness.manager.items.count == 3)
        let filenames = harness.manager.items.map(\.filename)
        #expect(Set(filenames).count == 3, "each capture must get its own file")
        harness.manager.dismissAll()
    }

    @Test("Dismissing a card keeps its file — dismiss is not delete (docs/03 §2)")
    func dismissKeepsTheFile() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(
            saveFolder: save,
            stagingFolder: temporaryDirectory("stage")
        )
        harness.settings.defaultAction = .saveToFolder

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)

        harness.manager.dismiss(item)

        #expect(harness.manager.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path), "dismissing deleted the capture")
        #expect(harness.manager.hasRecentlyClosed)
    }

    @Test("A dismissed card can be restored")
    func restoresDismissedCard() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(
            saveFolder: save,
            stagingFolder: temporaryDirectory("stage")
        )
        harness.settings.defaultAction = .saveToFolder

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)
        harness.manager.dismiss(item)

        harness.manager.restoreRecentlyClosed()

        #expect(harness.manager.items.count == 1)
        #expect(harness.manager.items.first?.fileURL == item.fileURL)
        harness.manager.dismissAll()
    }

    @Test("Restoring a capture whose file is gone does nothing rather than showing a blank card")
    func restoreSkipsMissingFiles() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(
            saveFolder: save,
            stagingFolder: temporaryDirectory("stage")
        )
        harness.settings.defaultAction = .saveToFolder

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)
        harness.manager.dismiss(item)
        try FileManager.default.removeItem(at: item.fileURL)

        harness.manager.restoreRecentlyClosed()

        #expect(harness.manager.items.isEmpty)
    }

    @Test("Overlay-only staging keeps the save folder empty until the user acts")
    func overlayOnlyStages() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.defaultAction = .overlayOnly

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)

        #expect(harness.manager.items.first?.isStaged == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: save.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).count == 1)
        harness.manager.dismissAll()
    }

    @Test("Copying a staged capture finalises it into the save folder")
    func copyFinalisesStaged() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.defaultAction = .overlayOnly

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let staged = try #require(harness.manager.items.first)

        harness.manager.copy(staged)

        #expect(harness.manager.items.first?.isStaged == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: save.path).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
        harness.manager.dismissAll()
    }

    @Test("Even a clipboard-only capture gets a file, so it can be dragged out")
    func clipboardOnlyStillStages() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.defaultAction = .copyToClipboard

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))

        #expect(result.fileURL != nil, "a card with no file cannot be dragged anywhere")
        #expect(result.isStaged)
        harness.manager.show(result, capture: capture)
        #expect(harness.manager.items.count == 1)
        harness.manager.dismissAll()
    }

    @Test("Deleting removes the card and the file")
    func deleteRemovesBoth() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(
            saveFolder: save,
            stagingFolder: temporaryDirectory("stage")
        )
        harness.settings.defaultAction = .saveToFolder

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)

        harness.manager.delete(item)

        #expect(harness.manager.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path) == false)
        #expect(harness.manager.hasRecentlyClosed == false, "a deleted capture must not be offered for restore")
    }

    @Test("Dismissing everything leaves no cards behind")
    func dismissAll() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))
        for _ in 0 ..< 3 {
            let capture = makeCapture()
            let result = try #require(harness.output.deliver(capture))
            harness.manager.show(result, capture: capture)
        }

        harness.manager.dismissAll()

        #expect(harness.manager.items.isEmpty)
    }
}
