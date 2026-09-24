import AppKit
import Testing
@testable import Kadr

/// Menus are part of the product (docs/17 §5 theme 4, T-SH-1).
///
/// Settings…, Kadr Help and Keyboard Shortcuts once had actions on `AppMenu` and no
/// target. `AppMenu` is outside the responder chain, so nothing answered them and they
/// stayed greyed out for a week without a test noticing. This walks the whole menu bar
/// and fails on any item nobody can answer.
@MainActor
@Suite("Agent main menu")
struct AppMenuTests {
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allItems) ?? [])
        }
    }

    /// Whether anything will answer the item: its explicit target, or — for a nil
    /// target — the application, its delegate, or the window and text-view responders a
    /// standard item (Close, Copy, Minimize, Undo) is meant to reach.
    private func resolves(_ item: NSMenuItem) -> Bool {
        // A submenu's parent answers itself (`submenuAction:` targets the submenu).
        guard let action = item.action, !item.hasSubmenu else { return true }
        if let target = item.target {
            return target.responds(to: action)
        }
        if NSApp.responds(to: action) || (NSApp.delegate?.responds(to: action) ?? false) {
            return true
        }
        return NSWindow.instancesRespond(to: action)
            || NSTextView.instancesRespond(to: action)
            || action == Selector(("undo:"))
            || action == Selector(("redo:"))
    }

    @Test("Every item in the menu bar resolves to something that answers it")
    func everyItemResolves() {
        let menu = AppMenu.shared.makeMenu()
        let items = allItems(menu).filter { !$0.isSeparatorItem && $0.action != nil }
        #expect(!items.isEmpty)
        for item in items {
            #expect(resolves(item), "“\(item.title)” (\(String(describing: item.action))) has nobody to answer it")
        }
    }

    @Test("AppMenu's own commands target AppMenu", arguments: [
        "Settings…", "Check for Updates…", "Kadr Help", "Keyboard Shortcuts",
        "Export Diagnostics…", "Report a Problem…"
    ])
    func ownCommandsHaveATarget(title: String) throws {
        let menu = AppMenu.shared.makeMenu()
        let item = try #require(allItems(menu).first { $0.title == title }, "no “\(title)” item")
        #expect(item.target === AppMenu.shared)
    }

    @Test("The Help menu is registered, so it gets the search field")
    func helpMenuIsRegistered() throws {
        let menu = AppMenu.shared.makeMenu()
        let help = try #require(menu.items.last?.submenu)
        #expect(NSApp.helpMenu === help)
        let titles = help.items.map(\.title)
        #expect(titles.contains("Report a Problem…"))
        #expect(titles.contains("Export Diagnostics…"))
    }
}
