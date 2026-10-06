import AppKit

/// Which window kind a menu item belongs to (docs/18 ED-11).
///
/// One process serves both annotation and studio windows from one menu bar. Items for the
/// other kind used to sit there greyed out — a Clip menu over a screenshot, a Tools menu
/// over a recording — so they are hidden instead while that kind of window is key.
enum EditorMenuScope: String {
    case annotation = "app.kadr.menu.annotation-only"
    case studio = "app.kadr.menu.studio-only"

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(rawValue)
    }
}

extension NSMenuItem {
    /// Marks the item as belonging to one window kind, and returns it for chaining.
    @discardableResult
    func scoped(to scope: EditorMenuScope) -> NSMenuItem {
        identifier = scope.identifier
        return self
    }
}

extension EditorAppDelegate {
    /// Re-scopes the menu bar whenever a window becomes key, for the app's lifetime.
    func observeKeyWindowForMenuScope() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didBecomeKeyNotification) {
                self?.applyMenuScope()
            }
        }
    }

    func applyMenuScope() {
        guard let menu = NSApp.mainMenu else { return }
        Self.applyScope(Self.scope(of: NSApp.keyWindow), to: menu)
    }

    /// The kind of the key window, read from its responder chain: both controllers sit in
    /// it. Nil — no window, Help, an alert — shows everything.
    static func scope(of window: NSWindow?) -> EditorMenuScope? {
        var responder: NSResponder? = window?.firstResponder
        while let current = responder {
            if current is EditorWindowController {
                return .annotation
            }
            if current is StudioWindowController {
                return .studio
            }
            responder = current.nextResponder
        }
        return nil
    }

    static func applyScope(_ scope: EditorMenuScope?, to menu: NSMenu) {
        for item in menu.items {
            if let itemScope = item.identifier.flatMap({ EditorMenuScope(rawValue: $0.rawValue) }) {
                item.isHidden = scope != nil && itemScope != scope
            }
            if let submenu = item.submenu {
                applyScope(scope, to: submenu)
            }
        }
    }
}
