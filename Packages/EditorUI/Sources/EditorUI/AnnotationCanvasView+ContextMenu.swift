import AnnotationModel
import AppKit

/// The canvas's right-click menu (docs/18 ED-11).
///
/// A right-click on an annotation selects it first, as Finder and Keynote do, then offers
/// the edits that apply to a selection. Every item is nil-targeted, so the window
/// controller that already answers the Edit menu validates and runs these too.
extension AnnotationCanvasView {
    override public func menu(for event: NSEvent) -> NSMenu? {
        let point = imagePoint(from: event)
        let selectable = model.document.commands.filter(\.isSelectable)
        if let hit = AnnotationHitTesting.topmost(in: selectable, at: point) {
            if !model.selection.contains(hit.id) {
                model.selection = [hit.id]
            }
        } else {
            model.selection = []
        }
        return Self.contextMenu(hasSelection: !model.selection.isEmpty)
    }

    /// The menu's items, by selector name, so a test can read them without a window.
    static func contextMenu(hasSelection: Bool) -> NSMenu {
        let menu = NSMenu(title: "Canvas")
        if hasSelection {
            menu.addItem(item("Cut", "cut:"))
            menu.addItem(item("Copy", "copy:"))
            menu.addItem(item("Paste", "paste:"))
            menu.addItem(item("Duplicate", "duplicate:"))
            menu.addItem(item("Delete", "delete:"))
            menu.addItem(.separator())
            menu.addItem(item("Bring to Front", "bringToFront:"))
            menu.addItem(item("Bring Forward", "bringForward:"))
            menu.addItem(item("Send Backward", "sendBackward:"))
            menu.addItem(item("Send to Back", "sendToBack:"))
        } else {
            menu.addItem(item("Paste", "paste:"))
            menu.addItem(item("Select All", "selectAll:"))
        }
        return menu
    }

    private static func item(_ title: String, _ selector: String) -> NSMenuItem {
        NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: "")
    }
}
