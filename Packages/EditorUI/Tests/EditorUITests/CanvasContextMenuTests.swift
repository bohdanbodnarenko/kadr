import AppKit
import Testing
@testable import EditorUI

/// The canvas's right-click menu (docs/18 ED-11).
@MainActor
@Suite("Canvas context menu")
struct CanvasContextMenuTests {
    @Test("A selection offers its edits and the arrange order")
    func withSelection() {
        let actions = AnnotationCanvasView.contextMenu(hasSelection: true).items.compactMap(\.action)
            .map(NSStringFromSelector)
        #expect(actions == [
            "cut:", "copy:", "paste:", "duplicate:", "delete:",
            "bringToFront:", "bringForward:", "sendBackward:", "sendToBack:"
        ])
    }

    @Test("Empty canvas offers Paste and Select All")
    func withoutSelection() {
        let actions = AnnotationCanvasView.contextMenu(hasSelection: false).items.compactMap(\.action)
            .map(NSStringFromSelector)
        #expect(actions == ["paste:", "selectAll:"])
    }
}
