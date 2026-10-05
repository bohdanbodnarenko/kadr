import AppKit
import Testing
@testable import KadrEditor

/// Every menu item does something: a dead item is a promise the editor breaks
/// (docs/17 menu walk, docs/18 X-6).
@MainActor
@Suite("Editor menu walk")
struct EditorMenuWalkTests {
    /// Classes an item's action can land on through the responder chain.
    private let responders: [AnyClass] = [
        EditorAppDelegate.self,
        EditorWindowController.self,
        StudioWindowController.self,
        NSApplication.self,
        NSWindow.self,
        NSTextView.self
    ]

    private func leaves(of menu: NSMenu, path: String = "") -> [(String, NSMenuItem)] {
        menu.items.flatMap { item -> [(String, NSMenuItem)] in
            if item.isSeparatorItem {
                return []
            }
            let name = path.isEmpty ? item.title : "\(path) ▸ \(item.title)"
            if let submenu = item.submenu {
                return leaves(of: submenu, path: name)
            }
            return [(name, item)]
        }
    }

    @Test("Every item has an action some responder answers")
    func everyItemIsWired() throws {
        let delegate = try #require(NSApp.delegate as? EditorAppDelegate)
        let items = leaves(of: delegate.makeMainMenu())
        #expect(items.count > 20)
        for (name, item) in items {
            guard let action = item.action else {
                Issue.record("“\(name)” has no action")
                continue
            }
            if let target = item.target as? NSObject {
                // Evaluated outside `#expect`: the macro's capture of an AnyObject-and-
                // Selector call crashes the Swift 6.3 compiler.
                let answers = target.responds(to: action)
                #expect(answers, "“\(name)”'s target does not answer its action")
                continue
            }
            let answered = responders.contains { $0.instancesRespond(to: action) }
            #expect(answered, "nothing in the responder chain answers “\(name)” (\(action))")
        }
    }

    @Test("No two items share a key equivalent")
    func keyEquivalentsAreUnique() throws {
        let delegate = try #require(NSApp.delegate as? EditorAppDelegate)
        var seen: [String: String] = [:]
        for (name, item) in leaves(of: delegate.makeMainMenu()) where !item.keyEquivalent.isEmpty {
            let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
            if let other = seen[key] {
                Issue.record("“\(name)” and “\(other)” share a shortcut")
            }
            seen[key] = name
        }
    }
}
