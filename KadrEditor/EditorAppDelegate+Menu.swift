import AppKit

extension EditorAppDelegate {
    /// A minimal menu bar: the commands a `.regular` app is expected to have.
    ///
    /// Built in code rather than in a nib. Without a nib, AppKit creates no Window or
    /// Services menu of its own: both are built here and handed to `NSApp` (T-ED-2). Open is the one that earns it — without it,
    /// import-from-Finder works only by dragging onto the icon (docs/09 U1.8).
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(makeAppMenuItem())
        main.addItem(makeFileMenuItem())
        main.addItem(makeEditMenuItem())
        main.addItem(makeViewMenuItem())
        main.addItem(makeClipMenuItem())
        main.addItem(makeWindowMenuItem())
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
        let services = NSMenu(title: String(localized: "Services"))
        appMenu.addItem(
            withTitle: String(localized: "Services"),
            action: nil,
            keyEquivalent: ""
        ).submenu = services
        NSApp.servicesMenu = services
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
        let recent = NSMenu(title: String(localized: "Open Recent"))
        recent.delegate = self
        fileMenu.addItem(withTitle: String(localized: "Open Recent"), action: nil, keyEquivalent: "").submenu = recent
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: String(localized: "Close"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        // Nil-targeted: the key window's controller answers, so these grey out in a Studio
        // or Help window instead of saving a hidden annotation window (T-ED-8).
        fileMenu.addItem(
            withTitle: String(localized: "Save"),
            action: #selector(EditorWindowController.saveDocument(_:)),
            keyEquivalent: "s"
        )
        let saveAs = fileMenu.addItem(
            withTitle: String(localized: "Save As…"),
            action: #selector(EditorWindowController.saveDocumentAs(_:)),
            keyEquivalent: "s"
        )
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        let saveProject = fileMenu.addItem(
            withTitle: String(localized: "Save Project…"),
            action: #selector(EditorWindowController.saveProjectDocument(_:)),
            keyEquivalent: "s"
        )
        saveProject.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(
            withTitle: String(localized: "Show in Finder"),
            action: #selector(EditorWindowController.showInFinder(_:)),
            keyEquivalent: ""
        )
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
            action: #selector(EditorWindowController.printDocument(_:)),
            keyEquivalent: "p"
        )
        fileItem.submenu = fileMenu
        return fileItem
    }

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
            action: #selector(EditorWindowController.copyFlattenedImage(_:)),
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
        // ⌥⌘= and ⌥⌘−: ⌘` is the system's cycle-windows shortcut, and a bare ⇧=
        // would take "+" from a text field (T-ED-10, HIG › Keyboard shortcuts).
        let increaseTool = viewMenu.addItem(
            withTitle: String(localized: "Increase Tool Size"),
            action: #selector(EditorWindowController.increaseToolSize(_:)),
            keyEquivalent: "="
        )
        increaseTool.keyEquivalentModifierMask = [.command, .option]
        let decreaseTool = viewMenu.addItem(
            withTitle: String(localized: "Decrease Tool Size"),
            action: #selector(EditorWindowController.decreaseToolSize(_:)),
            keyEquivalent: "-"
        )
        decreaseTool.keyEquivalentModifierMask = [.command, .option]
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
        NSApp.helpMenu = helpMenu
        return helpItem
    }

    /// The studio's timeline edits (T-ED-2). An annotation window has none of these
    /// actions, so the items grey out there.
    ///
    /// No key equivalents beyond ⌘K: the studio's own keys are bare (Space, and letters on
    /// the timeline), and a bare key in a menu fires before a focused text field sees it.
    private func makeClipMenuItem() -> NSMenuItem {
        let clipItem = NSMenuItem()
        let clipMenu = NSMenu(title: String(localized: "Clip"))
        clipMenu.addItem(
            withTitle: String(localized: "Play/Pause"),
            action: #selector(StudioWindowController.togglePlayback(_:)),
            keyEquivalent: ""
        )
        clipMenu.addItem(.separator())
        clipMenu.addItem(
            withTitle: String(localized: "Split Clip at Playhead"),
            action: #selector(StudioWindowController.splitClipAtPlayhead(_:)),
            keyEquivalent: "k"
        )
        clipMenu.addItem(
            withTitle: String(localized: "Trim Start to Playhead"),
            action: #selector(StudioWindowController.trimStartToPlayhead(_:)),
            keyEquivalent: ""
        )
        clipMenu.addItem(
            withTitle: String(localized: "Trim End to Playhead"),
            action: #selector(StudioWindowController.trimEndToPlayhead(_:)),
            keyEquivalent: ""
        )
        clipMenu.addItem(.separator())
        clipMenu.addItem(
            withTitle: String(localized: "Add Zoom"),
            action: #selector(StudioWindowController.addZoomAtPlayhead(_:)),
            keyEquivalent: ""
        )
        clipMenu.addItem(
            withTitle: String(localized: "Delete Clip or Zoom"),
            action: #selector(StudioWindowController.deleteTimelineSelection(_:)),
            keyEquivalent: ""
        )
        clipItem.submenu = clipMenu
        return clipItem
    }

    /// Minimize, Zoom, the window list and Bring All to Front (T-ED-2). AppKit appends the
    /// open windows itself once the menu is `NSApp.windowsMenu`.
    private func makeWindowMenuItem() -> NSMenuItem {
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(
            withTitle: String(localized: "Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: String(localized: "Zoom"),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: String(localized: "Bring All to Front"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return windowItem
    }
}

/// File ▸ Open Recent, rebuilt each time it opens (T-ED-9).
///
/// Built from `NSDocumentController`'s list rather than left to it: the editor has no
/// `NSDocument` subclass, so the controller's own menu would open nothing.
extension EditorAppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = menu.addItem(
                withTitle: FileManager.default.displayName(atPath: url.path),
                action: #selector(openRecentDocument(_:)),
                keyEquivalent: ""
            )
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        if menu.numberOfItems > 0 {
            menu.addItem(.separator())
        }
        menu.addItem(
            withTitle: String(localized: "Clear Menu"),
            action: #selector(clearRecentDocuments(_:)),
            keyEquivalent: ""
        )
    }
}
