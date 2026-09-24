import AppKit

extension EditorAppDelegate {
    /// A minimal menu bar: the commands a `.regular` app is expected to have.
    ///
    /// Built in code rather than in a nib because there are five items and a nib would be
    /// five items plus a file nobody reads. Open is the one that earns it — without it,
    /// import-from-Finder works only by dragging onto the icon (docs/09 U1.8).
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(makeAppMenuItem())
        main.addItem(makeFileMenuItem())
        main.addItem(makeEditMenuItem())
        main.addItem(makeViewMenuItem())
        let windowItem = NSMenuItem()
        windowItem.submenu = NSApp.windowsMenu
        main.addItem(windowItem)
        main.addItem(makeHelpMenuItem())
        return main
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: String(localized: "About Kadr Editor"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: "Services"),
            action: nil,
            keyEquivalent: ""
        ).submenu = NSApp.servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: "Hide Kadr Editor"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: String(localized: "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        ).keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: String(localized: "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: "Quit Kadr Editor"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        return appItem
    }

    private func makeFileMenuItem() -> NSMenuItem {
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "File"))
        fileMenu.addItem(withTitle: String(localized: "Open…"), action: #selector(importImage(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Save"), action: #selector(saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(
            withTitle: String(localized: "Save As…"),
            action: #selector(saveDocumentAs(_:)),
            keyEquivalent: "s"
        )
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        let saveProject = fileMenu.addItem(
            withTitle: String(localized: "Save Project…"),
            action: #selector(saveProjectDocument(_:)),
            keyEquivalent: "s"
        )
        saveProject.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(.separator())
        // Studio only: an annotation window has no `exportMovie:`, so the item greys itself
        // out there rather than needing to be built per window kind.
        fileMenu.addItem(
            withTitle: String(localized: "Export Video…"),
            action: #selector(StudioWindowController.exportMovie(_:)),
            keyEquivalent: "e"
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: String(localized: "Print…"),
            action: #selector(printDocument(_:)),
            keyEquivalent: "p"
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: String(localized: "Close"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileItem.submenu = fileMenu
        return fileItem
    }

    // Grandfathered when SwiftLint first covered KadrEditor/ (docs/17 T-REL-8); split it
    // when the editor's menus are next reworked (T-ED-2).
    // swiftlint:disable:next function_body_length
    private func makeEditMenuItem() -> NSMenuItem {
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(
            withTitle: String(localized: "Undo"),
            action: #selector(EditorWindowController.undo(_:)),
            keyEquivalent: "z"
        )
        let redo = editMenu.addItem(
            withTitle: String(localized: "Redo"),
            action: #selector(EditorWindowController.redo(_:)),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: String(localized: "Cut"),
            action: #selector(EditorWindowController.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: String(localized: "Copy"),
            action: #selector(EditorWindowController.copy(_:)),
            keyEquivalent: "c"
        )
        let copyFlattened = editMenu.addItem(
            withTitle: String(localized: "Copy Flattened Image"),
            action: #selector(copyFlattenedImage(_:)),
            keyEquivalent: "c"
        )
        copyFlattened.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(
            withTitle: String(localized: "Paste"),
            action: #selector(EditorWindowController.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: String(localized: "Select All"),
            action: #selector(EditorWindowController.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenu.addItem(
            withTitle: String(localized: "Duplicate"),
            action: #selector(EditorWindowController.duplicate(_:)),
            keyEquivalent: "d"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: String(localized: "Split Clip at Playhead"),
            action: #selector(StudioWindowController.splitClipAtPlayhead(_:)),
            keyEquivalent: "k"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: String(localized: "Bring to Front"),
            action: #selector(EditorWindowController.bringToFront(_:)),
            keyEquivalent: ""
        )
        editMenu.addItem(
            withTitle: String(localized: "Bring Forward"),
            action: #selector(EditorWindowController.bringForward(_:)),
            keyEquivalent: "]"
        )
        editMenu.addItem(
            withTitle: String(localized: "Send Backward"),
            action: #selector(EditorWindowController.sendBackward(_:)),
            keyEquivalent: "["
        )
        editMenu.addItem(
            withTitle: String(localized: "Send to Back"),
            action: #selector(EditorWindowController.sendToBack(_:)),
            keyEquivalent: ""
        )
        editMenu.addItem(.separator())
        let lock = editMenu.addItem(
            withTitle: String(localized: "Lock Objects"),
            action: #selector(EditorWindowController.toggleCanvasLock(_:)),
            keyEquivalent: "l"
        )
        lock.keyEquivalentModifierMask = [.command, .shift]
        editItem.submenu = editMenu
        return editItem
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: String(localized: "View"))
        viewMenu.addItem(
            withTitle: String(localized: "Show Inspector"),
            action: #selector(EditorWindowController.toggleInspector(_:)),
            keyEquivalent: "i"
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: String(localized: "Zoom In"),
            action: #selector(EditorWindowController.zoomIn(_:)),
            keyEquivalent: "="
        )
        viewMenu.addItem(
            withTitle: String(localized: "Zoom Out"),
            action: #selector(EditorWindowController.zoomOut(_:)),
            keyEquivalent: "-"
        )
        viewMenu.addItem(
            withTitle: String(localized: "Fit Canvas"),
            action: #selector(EditorWindowController.zoomToFit(_:)),
            keyEquivalent: "1"
        )
        viewMenu.addItem(
            withTitle: String(localized: "Actual Size"),
            action: #selector(EditorWindowController.zoomActualSize(_:)),
            keyEquivalent: "0"
        )
        viewMenu.addItem(.separator())
        let increaseTool = viewMenu.addItem(
            withTitle: String(localized: "Increase Tool Size"),
            action: #selector(EditorWindowController.increaseToolSize(_:)),
            keyEquivalent: "="
        )
        increaseTool.keyEquivalentModifierMask = [.shift]
        viewMenu.addItem(
            withTitle: String(localized: "Decrease Tool Size"),
            action: #selector(EditorWindowController.decreaseToolSize(_:)),
            keyEquivalent: "`"
        )
        viewItem.submenu = viewMenu
        return viewItem
    }

    private func makeHelpMenuItem() -> NSMenuItem {
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: String(localized: "Help"))
        helpMenu.addItem(withTitle: String(localized: "Kadr Help"), action: #selector(openHelp(_:)), keyEquivalent: "?")
        helpMenu.addItem(
            withTitle: String(localized: "Keyboard Shortcuts"),
            action: #selector(openKeyboardShortcuts(_:)),
            keyEquivalent: ""
        )
        helpItem.submenu = helpMenu
        return helpItem
    }
}
