import AppKit

/// Standard macOS menu bar for regular windows (Settings, History, Help, onboarding).
///
/// The agent is `LSUIElement` and spends its life as `.accessory`; this menu is idle
/// until a window brings the app forward (docs/14 UX-09, UX-28).
@MainActor
final class AppMenu: NSObject, NSMenuItemValidation {
    static let shared = AppMenu()

    func install() {
        NSApp.mainMenu = makeMenu()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSettingsSidebar(_:)) {
            let open = AppDelegate.shared.settingsWindowController.isOpen
            let hidden = AppDelegate.shared.settingsWindowController.isSidebarHidden
            menuItem.title = hidden ? "Show Sidebar" : "Hide Sidebar"
            return open
        }
        return true
    }

    @objc func toggleSettingsSidebar(_ sender: Any?) {
        NotificationCenter.default.post(name: .kadrToggleSettingsSidebar, object: nil)
    }

    @objc func openHelp(_ sender: Any?) {
        KadrHelpWindowController.shared.show(topic: .shortcuts)
    }

    @objc func openKeyboardShortcuts(_ sender: Any?) {
        KadrHelpWindowController.shared.show(topic: .shortcuts)
    }

    @objc func openSettings(_ sender: Any?) {
        AppDelegate.shared.openSettings()
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(makeAppMenuItem())
        main.addItem(makeEditMenuItem())
        main.addItem(makeViewMenuItem())
        let windowItem = NSMenuItem()
        windowItem.submenu = NSApp.windowsMenu ?? NSMenu(title: "Window")
        main.addItem(windowItem)
        main.addItem(makeHelpMenuItem())
        return main
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Kadr",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Kadr", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Kadr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        return appItem
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        return editItem
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let sidebar = viewMenu.addItem(
            withTitle: "Hide Sidebar",
            action: #selector(toggleSettingsSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebar.keyEquivalentModifierMask = [.command, .control]
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

extension Notification.Name {
    static let kadrToggleSettingsSidebar = Notification.Name("app.kadr.toggleSettingsSidebar")
}
