import AppKit
import EditorUI

/// The Tools menu (docs/18 ED-11): every tool with its letter, which is also how the letters
/// become discoverable.
extension EditorWindowController {
    @objc func chooseTool(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              EditorTool.allCases.indices.contains(item.tag)
        else { return }
        model.selectTool(EditorTool.allCases[item.tag])
    }

    /// Edit ▸ Delete and the canvas menu's Delete; ⌫ on the canvas does the same.
    @objc func delete(_ sender: Any?) {
        model.deleteSelection()
    }

    /// Enabled only while the canvas has the keyboard. The items carry bare letters as key
    /// equivalents, and a disabled item lets the key through, so typing an "a" into a text
    /// box or an inspector field never switches to the arrow.
    func validateToolItem(_ item: NSMenuItem) -> Bool {
        guard EditorTool.allCases.indices.contains(item.tag) else { return false }
        item.state = model.tool == EditorTool.allCases[item.tag] ? .on : .off
        return window?.firstResponder is AnnotationCanvasView
    }
}

extension EditorAppDelegate {
    func makeToolsMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "Tools"))
        for (index, tool) in EditorTool.allCases.enumerated() {
            let entry = menu.addItem(
                withTitle: tool.title,
                action: #selector(EditorWindowController.chooseTool(_:)),
                keyEquivalent: String(tool.shortcut)
            )
            entry.keyEquivalentModifierMask = []
            entry.tag = index
        }
        item.submenu = menu
        return item
    }
}
