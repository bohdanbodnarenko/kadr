import AppKit
import CaptureCore
import CoreGraphics
import Foundation
import HistoryKit
import MediaExport
import SettingsKit
import Shared
import Testing
import UniformTypeIdentifiers
@testable import Kadr

/// Output policy (docs/07 H3–H5, M1, M4; docs/09 U0.4).
@MainActor
@Suite("Capture output policy", .serialized)
struct CaptureOutputPolicyTests {
    /// M4: one capture action, one clipboard. Every display used to overwrite the last.
    @Test("A multi-display capture writes every file but claims the clipboard once")
    func multiDisplayDeliversEveryFileOnce() async throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))
        harness.settings.defaultAction = .copyAndSave

        let captures = [makeCapture(), makeCapture(), makeCapture()]
        let delivered = await harness.output.deliverOffMain(captures)

        #expect(delivered.count == 3, "no display may be dropped")
        #expect(delivered.filter(\.result.copiedToClipboard).count == 1, "one pasteboard, one winner")
        #expect(try FileManager.default.contentsOfDirectory(atPath: save.path).count == 3)
    }

    @Test("Every delivered file has a distinct name")
    func multiDisplayFilesDoNotCollide() async {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))
        harness.settings.defaultAction = .saveToFolder

        let delivered = await harness.output.deliverOffMain([makeCapture(), makeCapture()])
        let urls = Set(delivered.compactMap(\.result.fileURL))
        #expect(urls.count == 2)
    }

    /// H4: the export runs off the main actor, and still comes back with everything the
    /// caller needs — including the clipboard write, which has to happen back on main.
    @Test("An off-main export still copies and still writes a file")
    func offMainExportIsComplete() async throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))
        harness.settings.defaultAction = .copyAndSave

        let result = try #require(await harness.output.deliverOffMain(makeCapture()))

        #expect(result.copiedToClipboard)
        let url = try #require(result.fileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Ask-where-to-save stages instead of writing silently")
    func promptSaveStages() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.afterCapture[.screenshot] = [.overlay, .save, .promptSave]

        let result = try #require(harness.output.deliver(makeCapture()))

        #expect(result.isStaged)
        #expect(result.fileURL?.deletingLastPathComponent().path == stage.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: save.path).isEmpty)
    }

    @Test("Save without asking writes to the folder immediately")
    func silentSaveDoesNotStage() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.afterCapture[.screenshot] = [.overlay, .save]

        let result = try #require(harness.output.deliver(makeCapture()))

        #expect(!result.isStaged)
        #expect(result.fileURL?.deletingLastPathComponent().path == save.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
    }

    @Test("Moving a staged capture to a picked path unstages it")
    func moveCaptureToPickedPath() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let picked = temporaryDirectory("picked")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.defaultAction = .overlayOnly

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)
        #expect(item.isStaged)

        let destination = picked.appendingPathComponent("named.png")
        let moved = try #require(harness.manager.moveCapture(item, to: destination))

        #expect(moved == destination)
        #expect(harness.manager.items.first?.isStaged == false)
        #expect(harness.manager.items.first?.fileURL == destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path) == false)
        harness.manager.dismissAll()
    }

    /// H5: "deleted" has to mean deleted, including the library's own copy.
    @Test("Deleting a card removes the capture from the library too")
    func deleteRemovesTheLibraryCopy() async throws {
        let root = temporaryDirectory("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore.open(root: root)

        let save = temporaryDirectory("save")
        let history = HistoryController(settings: AppSettings(store: throwawayDefaults()), store: store)
        let harness = makeManager(
            saveFolder: save,
            stagingFolder: temporaryDirectory("stage"),
            history: history
        )
        harness.settings.defaultAction = .saveToFolder

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)

        // The ingest is queued, so wait for it rather than guessing at a duration.
        #expect(await settles(store, itemCount: 1), "the capture should reach the library")

        harness.manager.delete(item)

        #expect(await settles(store, itemCount: 0), "a deleted capture must not survive in the library")
    }

    /// Polls until the library holds `itemCount` records, or gives up.
    private func settles(_ store: HistoryStore, itemCount: Int, within: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            if await (try? store.storageUsage().itemCount) == itemCount {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
