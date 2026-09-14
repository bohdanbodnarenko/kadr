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
            withTitle: "About Kadr Editor",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Services",
            action: nil,
            keyEquivalent: ""
        ).submenu = NSApp.servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Kadr Editor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        ).keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Kadr Editor",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        return appItem
    }

    private func makeFileMenuItem() -> NSMenuItem {
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(importImage(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(
            withTitle: "Save As…",
            action: #selector(saveDocumentAs(_:)),
            keyEquivalent: "s"
        )
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        let saveProject = fileMenu.addItem(
            withTitle: "Save Project…",
            action: #selector(saveProjectDocument(_:)),
            keyEquivalent: "s"
        )
        saveProject.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print…", action: #selector(printDocument(_:)), keyEquivalent: "p")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        return fileItem
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(EditorWindowController.undo(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(
            withTitle: "Redo",
            action: #selector(EditorWindowController.redo(_:)),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(EditorWindowController.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(EditorWindowController.copy(_:)), keyEquivalent: "c")
        let copyFlattened = editMenu.addItem(
            withTitle: "Copy Flattened Image",
            action: #selector(copyFlattenedImage(_:)),
            keyEquivalent: "c"
        )
        copyFlattened.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "Paste", action: #selector(EditorWindowController.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(EditorWindowController.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenu.addItem(
            withTitle: "Duplicate",
            action: #selector(EditorWindowController.duplicate(_:)),
            keyEquivalent: "d"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Bring to Front",
            action: #selector(EditorWindowController.bringToFront(_:)),
            keyEquivalent: ""
        )
        editMenu.addItem(
            withTitle: "Bring Forward",
            action: #selector(EditorWindowController.bringForward(_:)),
            keyEquivalent: "]"
        )
        editMenu.addItem(
            withTitle: "Send Backward",
            action: #selector(EditorWindowController.sendBackward(_:)),
            keyEquivalent: "["
        )
        editMenu.addItem(
            withTitle: "Send to Back",
            action: #selector(EditorWindowController.sendToBack(_:)),
            keyEquivalent: ""
        )
        editMenu.addItem(.separator())
        let lock = editMenu.addItem(
            withTitle: "Lock Objects",
            action: #selector(EditorWindowController.toggleCanvasLock(_:)),
            keyEquivalent: "l"
        )
        lock.keyEquivalentModifierMask = [.command, .shift]
        editItem.submenu = editMenu
        return editItem
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(
            withTitle: "Show Inspector",
            action: #selector(EditorWindowController.toggleInspector(_:)),
            keyEquivalent: "i"
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(
            withTitle: "Zoom Out",
            action: #selector(EditorWindowController.zoomOut(_:)),
            keyEquivalent: "-"
        )
        viewMenu.addItem(
            withTitle: "Fit Canvas",
            action: #selector(EditorWindowController.zoomToFit(_:)),
            keyEquivalent: "1"
        )
        viewMenu.addItem(
            withTitle: "Actual Size",
            action: #selector(EditorWindowController.zoomActualSize(_:)),
            keyEquivalent: "0"
        )
        viewMenu.addItem(.separator())
        let increaseTool = viewMenu.addItem(
            withTitle: "Increase Tool Size",
            action: #selector(EditorWindowController.increaseToolSize(_:)),
            keyEquivalent: "="
        )
        increaseTool.keyEquivalentModifierMask = [.shift]
        viewMenu.addItem(
            withTitle: "Decrease Tool Size",
            action: #selector(EditorWindowController.decreaseToolSize(_:)),
            keyEquivalent: "`"
        )
        viewItem.submenu = viewMenu
        return viewItem
    }

    private func makeHelpMenuItem() -> NSMenuItem {
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Kadr Help", action: #selector(openHelp(_:)), keyEquivalent: "?")
        helpMenu.addItem(
            withTitle: "Keyboard Shortcuts",
            action: #selector(openKeyboardShortcuts(_:)),
            keyEquivalent: ""
        )
        helpItem.submenu = helpMenu
        return helpItem
    }
}
