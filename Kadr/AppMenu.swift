import AppKit

/// Standard macOS menu bar for regular windows (Settings, History, Help, onboarding).
///
/// The agent is `LSUIElement` and spends its life as `.accessory`; this menu is idle
/// until a window brings the app forward (docs/14 UX-09, UX-28).
///
/// Every item whose action lives here sets `target = self`. `AppMenu` is an `NSObject`
/// outside the responder chain, so an item with a nil target and one of these selectors
/// found nobody to answer it: Settings…, Kadr Help and Keyboard Shortcuts were greyed out
/// whenever a Kadr window was in front, and Help could not be opened at all (docs/17
/// T-SH-1). `AppMenuTests` walks the finished menu and fails on any item nobody answers.
@MainActor
final class AppMenu: NSObject, NSMenuItemValidation {
    static let shared = AppMenu()

    func install() {
        NSApp.mainMenu = makeMenu()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return UpdaterManager.shared.canCheckForUpdates
        }
        if menuItem.action == #selector(toggleSettingsSidebar(_:)) {
            let open = AppDelegate.shared.settingsWindowController.isOpen
            let hidden = AppDelegate.shared.settingsWindowController.isSidebarHidden
            menuItem.title = hidden
                ? String(localized: "Show Sidebar")
                : String(localized: "Hide Sidebar")
            return open
        }
        return true
    }

    @objc func toggleSettingsSidebar(_ sender: Any?) {
        NotificationCenter.default.post(name: .kadrToggleSettingsSidebar, object: nil)
    }

    @objc func openHelp(_ sender: Any?) {
        KadrHelpWindowController.shared.show(topic: .gettingStarted)
    }

    @objc func showWelcome(_ sender: Any?) {
        AppDelegate.shared.showOnboarding()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdaterManager.shared.checkForUpdates()
    }

    @objc func exportDiagnostics(_ sender: Any?) {
        Task { await AppDelegate.shared.exportDiagnostics() }
    }

    @objc func reportProblem(_ sender: Any?) {
        Task { await AppDelegate.shared.reportProblem() }
    }

    @objc func openKeyboardShortcuts(_ sender: Any?) {
        KadrHelpWindowController.shared.show(topic: .shortcuts)
    }

    @objc func openSettings(_ sender: Any?) {
        AppDelegate.shared.openSettings()
    }

    func makeMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(makeAppMenuItem())
        main.addItem(makeFileMenuItem())
        main.addItem(makeEditMenuItem())
        main.addItem(makeViewMenuItem())
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
        main.addItem(windowItem)
        main.addItem(makeHelpMenuItem())
        return main
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: String(localized: "About Kadr"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(
            withTitle: String(localized: "Check for Updates…"),
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: "Settings…"),
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: "Hide Kadr"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: String(localized: "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: String(localized: "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: "Quit Kadr"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        target(appMenu)
        appItem.submenu = appMenu
        return appItem
    }

    private func makeFileMenuItem() -> NSMenuItem {
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "File"))
        fileMenu.addItem(
            withTitle: String(localized: "Close"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileItem.submenu = fileMenu
        return fileItem
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(
            withTitle: String(localized: "Redo"),
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: String(localized: "Select All"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        return editItem
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: String(localized: "View"))
        let sidebar = viewMenu.addItem(
            withTitle: String(localized: "Hide Sidebar"),
            action: #selector(toggleSettingsSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebar.keyEquivalentModifierMask = [.command, .control]
        target(viewMenu)
        viewItem.submenu = viewMenu
        return viewItem
    }

    private func makeHelpMenuItem() -> NSMenuItem {
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: String(localized: "Help"))
        helpMenu.addItem(
            withTitle: String(localized: "Kadr Help"),
            action: #selector(openHelp(_:)),
            keyEquivalent: "?"
        )
        helpMenu.addItem(
            withTitle: String(localized: "Keyboard Shortcuts"),
            action: #selector(openKeyboardShortcuts(_:)),
            keyEquivalent: ""
        )
        helpMenu.addItem(
            withTitle: String(localized: "Show Welcome…"),
            action: #selector(showWelcome(_:)),
            keyEquivalent: ""
        )
        helpMenu.addItem(.separator())
        helpMenu.addItem(
            withTitle: String(localized: "Export Diagnostics…"),
            action: #selector(exportDiagnostics(_:)),
            keyEquivalent: ""
        )
        helpMenu.addItem(
            withTitle: String(localized: "Report a Problem…"),
            action: #selector(reportProblem(_:)),
            keyEquivalent: ""
        )
        target(helpMenu)
        helpItem.submenu = helpMenu
        // Registering it is what gives the Help menu its search field (docs/17 T-SH-9).
        NSApp.helpMenu = helpMenu
        return helpItem
    }

    /// Points every item whose action is one of `AppMenu`'s own at `self`.
    ///
    /// Items with a standard responder action (`terminate:`, `copy:`, `performClose:`) keep
    /// a nil target: those are meant to travel the responder chain.
    private func target(_ menu: NSMenu) {
        for item in menu.items {
            guard let action = item.action, responds(to: action) else { continue }
            item.target = self
        }
    }
}

extension Notification.Name {
    static let kadrToggleSettingsSidebar = Notification.Name("app.kadr.toggleSettingsSidebar")
}
