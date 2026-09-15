import Foundation
import Shared
import Testing
@testable import Kadr

/// A capture deleted in the editor loses its overlay card (docs/03 §3).
@MainActor
@Suite("Editor deletions")
struct EditorDeletionTests {
    private func card(_ url: URL) -> QuickAccessItem {
        QuickAccessItem(
            fileURL: url,
            isStaged: false,
            pixelSize: PixelSize(width: 10, height: 10),
            capturedAt: Date(),
            displayID: nil
        )
    }

    private var trash: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)
    }

    @Test("A capture trashed in the editor loses its card; the others stay")
    func trashedCaptureLosesItsCard() {
        let folder = temporaryDirectory("editor-delete")
        let manager = makeManager(saveFolder: folder, stagingFolder: folder).manager
        let kept = folder.appendingPathComponent("kept.png")
        let gone = folder.appendingPathComponent("gone.png")
        manager.items = [card(kept), card(gone)]

        manager.captureWasTrashed(.init(original: gone, trashed: trash.appendingPathComponent("gone.png")))

        #expect(manager.items.map(\.fileURL) == [kept])
    }

    @Test("A notice that does not point into the Trash changes nothing")
    func noticeOutsideTheTrashIsIgnored() {
        let folder = temporaryDirectory("editor-delete-ignored")
        let manager = makeManager(saveFolder: folder, stagingFolder: folder).manager
        let capture = folder.appendingPathComponent("capture.png")
        manager.items = [card(capture)]

        manager.captureWasTrashed(.init(original: capture, trashed: folder.appendingPathComponent("elsewhere.png")))

        #expect(manager.items.map(\.fileURL) == [capture])
    }
}
