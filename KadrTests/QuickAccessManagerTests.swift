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
    func dismissAll() async throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))
        for _ in 0 ..< 3 {
            let capture = makeCapture()
            let result = try #require(harness.output.deliver(capture))
            harness.manager.show(result, capture: capture)
        }

        harness.manager.dismissAll()
        try await waitForEmptyStack(harness.manager)

        #expect(harness.manager.items.isEmpty)
    }

    @Test("Close all removes cards one at a time so the stack can animate")
    func dismissAllIsSequential() async throws {
        let save = temporaryDirectory("save-seq")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage-seq"))
        for _ in 0 ..< 3 {
            let capture = makeCapture()
            let result = try #require(harness.output.deliver(capture))
            harness.manager.show(result, capture: capture)
        }

        harness.manager.dismissAll()
        #expect(harness.manager.items.count == 3)

        try await Task.sleep(for: QuickAccessManager.dismissCascadeInterval)
        #expect(harness.manager.items.count == 2)

        try await waitForEmptyStack(harness.manager)
        #expect(harness.manager.items.isEmpty)
    }

    @Test("Restore recently closed falls through to history when the overlay stack is empty")
    func restoreFromHistory() async throws {
        let save = temporaryDirectory("save")
        let historyRoot = temporaryDirectory("history")
        let store = try HistoryStore.open(root: historyRoot)
        let suite = UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not open a throwaway defaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(store: defaults)
        settings.saveFolderPath = save.path
        settings.defaultAction = .saveToFolder

        let output = CaptureOutput(
            settings: settings,
            exporter: CaptureExporter(staging: StagingArea(directory: temporaryDirectory("stage")))
        )
        let capture = makeCapture()
        let result = try #require(output.deliver(capture))
        let fileURL = try #require(result.fileURL)
        let record = try await store.ingest(HistoryIngest(
            sourceURL: fileURL,
            kind: .image,
            pixelSize: PixelSize(width: 20, height: 10),
            originalFilename: "from-history.png"
        ))

        let history = HistoryController(settings: settings, store: store)
        let harness = makeManager(
            saveFolder: save,
            stagingFolder: temporaryDirectory("stage"),
            history: history
        )

        harness.manager.restoreRecentlyClosed()
        for _ in 0 ..< 20 where harness.manager.items.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(harness.manager.items.count == 1)
        #expect(harness.manager.items.first?.displayName == record.originalFilename)
        harness.manager.dismissAll()
    }
}

/// Dragging a capture out of the overlay (docs/03 §2, §6; docs/07 C1; docs/09 U0.1).
///
/// The product's signature interaction, and the one the review found broken under default
/// settings: the drag finalised the staged file — moving it — and then handed the receiver
/// the path it had *before* the move.
@MainActor
@Suite("Quick Access drags", .serialized)
struct QuickAccessDragTests {
    /// The C1 regression, stated as the thing that must be true: whatever the drag hands
    /// over has to exist.
    @Test("A staged capture resolves to a file that is really there")
    func stagedDragResolvesToTheMovedFile() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.defaultAction = .overlayOnly

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let staged = try #require(harness.manager.items.first)
        #expect(staged.isStaged)

        let dragged = try #require(harness.manager.resolveForDrag(staged))

        #expect(FileManager.default.fileExists(atPath: dragged.path), "the receiver must get a real file")
        #expect(dragged.deletingLastPathComponent().path == save.path, "resolving finalises the capture")
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
        harness.manager.dismissAll()
    }

    @Test("An already-saved capture resolves to where it already is")
    func savedDragResolvesInPlace() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))
        harness.settings.defaultAction = .saveToFolder

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)

        let dragged = try #require(harness.manager.resolveForDrag(item))
        #expect(dragged == item.fileURL)
        #expect(FileManager.default.fileExists(atPath: dragged.path))
        harness.manager.dismissAll()
    }

    /// The other half of C1: dismissing at drag *start* threw the capture away when the
    /// user changed their mind mid-drag.
    @Test("A cancelled drag leaves the card and its file alone")
    func cancelledDragKeepsTheCard() throws {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.defaultAction = .overlayOnly
        harness.settings.overlayDismissOnDrag = true

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)

        harness.manager.dragCompleted(item, accepted: false)

        #expect(harness.manager.items.count == 1, "an abandoned drag must not dismiss the card")
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).count == 1)
        harness.manager.dismissAll()
    }

    @Test("An accepted drop dismisses the card when the setting asks for it")
    func acceptedDropDismisses() throws {
        let harness = makeManager(
            saveFolder: temporaryDirectory("save"),
            stagingFolder: temporaryDirectory("stage")
        )
        harness.settings.overlayDismissOnDrag = true

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)

        harness.manager.dragCompleted(item, accepted: true)
        #expect(harness.manager.items.isEmpty)
    }

    @Test("With the setting off, even an accepted drop keeps the card")
    func acceptedDropKeepsCardWhenSettingIsOff() throws {
        let harness = makeManager(
            saveFolder: temporaryDirectory("save"),
            stagingFolder: temporaryDirectory("stage")
        )
        harness.settings.overlayDismissOnDrag = false

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)

        harness.manager.dragCompleted(item, accepted: true)
        #expect(harness.manager.items.count == 1)
        harness.manager.dismissAll()
    }

    @Test("A capture whose file has vanished resolves to nothing rather than a dead path")
    func missingFileResolvesToNil() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))
        harness.settings.defaultAction = .saveToFolder

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)
        try FileManager.default.removeItem(at: item.fileURL)

        #expect(harness.manager.resolveForDrag(item) == nil)
        harness.manager.dismissAll()
    }

    /// The promise tells the receiver what the file is; saying "PNG" for a JPEG or an MP4
    /// is what produced garbage pastes (docs/07 M1).
    @Test("The promised type follows the file", arguments: [
        ("shot.png", UTType.png),
        ("shot.jpeg", UTType.jpeg),
        ("shot.heic", UTType.heic),
        ("clip.mp4", UTType.mpeg4Movie)
    ])
    func contentTypeFollowsTheFile(name: String, expected: UTType) {
        let item = QuickAccessItem(
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
            isStaged: false,
            pixelSize: PixelSize(width: 10, height: 10),
            capturedAt: Date(),
            displayID: nil,
            isVideo: name.hasSuffix("mp4")
        )
        #expect(item.contentType == expected)
    }

    @Test("Hiding the stack does not dismiss cards (CleanShot §6.3)")
    func hidingKeepsCards() throws {
        let save = temporaryDirectory("save")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage"))
        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)

        harness.manager.toggleHidden()
        #expect(harness.manager.areHidden)
        #expect(harness.manager.items.count == 1)

        harness.manager.toggleHidden()
        #expect(!harness.manager.areHidden)
        harness.manager.dismissAll()
    }

    @Test("Save all finalises every staged card")
    func saveAllDismissesCards() async throws {
        let save = temporaryDirectory("save-all")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage-all"))
        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        #expect(harness.manager.items.count == 1)

        harness.manager.saveAll()
        try await waitForEmptyStack(harness.manager)
        #expect(harness.manager.items.isEmpty)
    }

    @Test("Save all dismisses every card without skipping any")
    func saveAllDismissesEveryCard() async throws {
        let save = temporaryDirectory("save-all-multi")
        let stage = temporaryDirectory("stage-all-multi")
        let harness = makeManager(saveFolder: save, stagingFolder: stage)
        harness.settings.defaultAction = .overlayOnly

        for _ in 0 ..< 3 {
            let capture = makeCapture()
            let result = try #require(harness.output.deliver(capture))
            harness.manager.show(result, capture: capture)
        }
        #expect(harness.manager.items.count == 3)

        harness.manager.saveAll()
        try await waitForEmptyStack(harness.manager)
        #expect(harness.manager.items.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: save.path).count == 3)
    }

    @Test("A promise for a plain file carries that file's name")
    func payloadForAPlainFile() {
        let url = URL(fileURLWithPath: "/tmp/Kadr-2026-08-28.png")
        let payload = FilePromisePayload.file(at: url)
        #expect(payload.suggestedName == "Kadr-2026-08-28.png")
        #expect(payload.contentType == .png)
        #expect(payload.resolve() == url)
    }

    @Test("Rotate 90° swaps the card's pixel size (CleanShot §6.2)")
    func rotateSwapsPixelSize() throws {
        let save = temporaryDirectory("save-rotate")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage-rotate"))
        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)
        #expect(item.pixelSize == PixelSize(width: 20, height: 10))
        #expect(item.canScaleRetina)

        harness.manager.rotate(item)

        let rotated = try #require(harness.manager.items.first)
        #expect(rotated.pixelSize == PixelSize(width: 10, height: 20))
        #expect(rotated.contentRevision == 1)
        #expect(FileManager.default.fileExists(atPath: rotated.fileURL.path))
        harness.manager.dismissAll()
    }

    @Test("Scale Retina to 1× halves a 2× capture")
    func scaleRetinaHalves() throws {
        let save = temporaryDirectory("save-1x")
        let harness = makeManager(saveFolder: save, stagingFolder: temporaryDirectory("stage-1x"))
        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        let item = try #require(harness.manager.items.first)

        harness.manager.scaleRetina(item)

        let scaled = try #require(harness.manager.items.first)
        #expect(scaled.pixelSize == PixelSize(width: 10, height: 5))
        #expect(scaled.scale == .oneToOne)
        #expect(!scaled.canScaleRetina)
        harness.manager.dismissAll()
    }

    @Test("A recording cannot be rotated from the overlay")
    func videoSkipsRotate() throws {
        let item = QuickAccessItem(
            fileURL: URL(fileURLWithPath: "/tmp/clip.mp4"),
            isStaged: false,
            pixelSize: PixelSize(width: 10, height: 10),
            capturedAt: Date(),
            displayID: nil,
            isVideo: true
        )
        #expect(!item.canScaleRetina)
        let harness = makeManager(
            saveFolder: temporaryDirectory("save-vid"),
            stagingFolder: temporaryDirectory("stage-vid")
        )
        harness.manager.rotate(item)
        #expect(harness.manager.items.isEmpty)
    }
}
