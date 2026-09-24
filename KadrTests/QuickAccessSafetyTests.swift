import AppKit
import Foundation
import MediaExport
import SettingsKit
import Shared
import Testing
@testable import Kadr

/// docs/17 T-OUT-1, T-OUT-5, T-OUT-7, T-OUT-11: the card paths that used to lose work.
@Suite("Card keys")
struct CardKeyCommandTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let expected: CardKeyCommand?

        var testDescription: String {
            "key \(keyCode) modifiers \(modifiers.rawValue)"
        }
    }

    static let rows: [Row] = [
        Row(keyCode: 51, modifiers: [], expected: .delete),
        Row(keyCode: 117, modifiers: [.function], expected: .delete),
        // ⌘⌫ is Finder's Move to Trash, not ours.
        Row(keyCode: 51, modifiers: [.command], expected: nil),
        Row(keyCode: 51, modifiers: [.option], expected: nil),
        Row(keyCode: 51, modifiers: [.capsLock], expected: .delete),
        Row(keyCode: 53, modifiers: [], expected: .dismiss),
        Row(keyCode: 49, modifiers: [], expected: .quickLook),
        Row(keyCode: 49, modifiers: [.shift], expected: nil),
        Row(keyCode: 36, modifiers: [], expected: .save),
        Row(keyCode: 76, modifiers: [.numericPad], expected: .save),
        Row(keyCode: 1, modifiers: [.command], expected: .save),
        Row(keyCode: 1, modifiers: [.command, .shift], expected: nil),
        Row(keyCode: 8, modifiers: [.command], expected: .copy),
        Row(keyCode: 14, modifiers: [.command], expected: .annotate),
        Row(keyCode: 35, modifiers: [.command], expected: .pin),
        Row(keyCode: 13, modifiers: [.command], expected: .dismiss),
        Row(keyCode: 13, modifiers: [.command, .option], expected: nil),
        Row(keyCode: 0, modifiers: [], expected: nil)
    ]

    @Test("Keys map to card commands only with exactly the modifiers they expect", arguments: rows)
    func table(row: Row) {
        #expect(CardKeyCommand.resolve(keyCode: row.keyCode, modifiers: row.modifiers) == row.expected)
    }
}

@MainActor
@Suite("Quick Access safety", .serialized)
struct QuickAccessSafetyTests {
    private func savedCard(_ harness: TestHarness) throws -> QuickAccessItem {
        harness.settings.defaultAction = .saveToFolder
        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        harness.manager.show(result, capture: capture)
        return try #require(harness.manager.items.first)
    }

    private func externalFile() throws -> URL {
        let url = temporaryDirectory("user").appendingPathComponent("Mine.png")
        let data = try Data(contentsOf: #require(harness().output.deliver(makeCapture())?.fileURL))
        try data.write(to: url)
        return url
    }

    private func harness() -> TestHarness {
        makeManager(saveFolder: temporaryDirectory("save"), stagingFolder: temporaryDirectory("stage"))
    }

    @Test("Undo after delete puts the file and the card back")
    func undoDelete() throws {
        let harness = harness()
        let item = try savedCard(harness)

        harness.manager.delete(item)
        #expect(!FileManager.default.fileExists(atPath: item.fileURL.path))
        #expect(harness.manager.pendingDeletions[item.id] != nil)

        harness.manager.undoDeletion(id: item.id)
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
        #expect(harness.manager.items.contains { $0.id == item.id })
        #expect(harness.manager.pendingDeletions.isEmpty)
        FailurePresenter.dismiss()
        harness.manager.dismissAll()
    }

    @Test("A file Kadr did not create cannot be deleted from its card")
    func externalFilesAreNeverTrashed() throws {
        let harness = harness()
        let url = try externalFile()
        #expect(harness.manager.presentExternalFile(at: url))
        let item = try #require(harness.manager.items.first)

        #expect(!harness.manager.canDelete(item))
        #expect(!QuickAccessStackLayout.showsTrashButton(for: item))
        harness.manager.delete(item)
        #expect(FileManager.default.fileExists(atPath: url.path))
        harness.manager.dismissAll()
    }

    @Test("Save on an external card copies it into the save folder and leaves the original")
    func saveCopiesExternalFiles() throws {
        let harness = harness()
        let url = try externalFile()
        harness.manager.presentExternalFile(at: url)
        let item = try #require(harness.manager.items.first)

        harness.manager.save(item)

        #expect(FileManager.default.fileExists(atPath: url.path), "Save moved the user's own file")
        let saved = try FileManager.default.contentsOfDirectory(atPath: harness.settings.saveFolder.path)
        #expect(saved == ["Mine.png"])
        #expect(harness.manager.items.isEmpty)
    }

    @Test("Rotating an external card works on a copy")
    func transformsCopyExternalFiles() throws {
        let harness = harness()
        let url = try externalFile()
        let before = try Data(contentsOf: url)
        harness.manager.presentExternalFile(at: url)
        let item = try #require(harness.manager.items.first)

        harness.manager.rotate(item)

        #expect(try Data(contentsOf: url) == before, "the user's file was rewritten in place")
        let card = try #require(harness.manager.items.first)
        #expect(card.fileURL != url)
        #expect(card.origin == .capture)
        #expect(card.isStaged)
        harness.manager.dismissAll()
    }

    @Test("The save name keeps the file's real extension", arguments: [
        ("3fa9c1.heic", "Receipt.png", "Receipt.heic"),
        ("3fa9c1.jpg", "Receipt", "Receipt.jpg"),
        ("Shot.png", nil as String?, "Shot.png")
    ])
    func saveFilename(onDisk: String, display: String?, expected: String) {
        let item = QuickAccessItem(
            fileURL: URL(fileURLWithPath: "/tmp/\(onDisk)"),
            isStaged: false,
            pixelSize: PixelSize(width: 1, height: 1),
            capturedAt: Date(),
            displayID: nil,
            displayName: display
        )
        #expect(QuickAccessManager.saveFilename(for: item) == expected)
    }

    @Test("With no card up, feedback goes to the failure presenter instead of nowhere")
    func feedbackWithoutACard() {
        let harness = harness()
        harness.manager.presentFeedback(.failure("Nope"))
        #expect(harness.manager.feedbackStatus == nil)
        #expect(FailurePresenter.isPresenting)
        FailurePresenter.dismiss()
    }
}
