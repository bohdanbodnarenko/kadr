import AppKit
import Testing
@testable import KadrEditor

/// Studio items hide over an annotation window and the other way round (docs/18 ED-11).
@MainActor
@Suite("Editor menu scope")
struct EditorMenuScopeTests {
    private func visibleTopLevelTitles(for scope: EditorMenuScope?) throws -> [String] {
        let delegate = try #require(NSApp.delegate as? EditorAppDelegate)
        let menu = delegate.makeMainMenu()
        EditorAppDelegate.applyScope(scope, to: menu)
        return menu.items.filter { !$0.isHidden }.compactMap { $0.submenu?.title }
    }

    @Test("An annotation window hides the Clip menu and keeps Tools")
    func annotationScope() throws {
        let titles = try visibleTopLevelTitles(for: .annotation)
        #expect(titles.contains("Tools"))
        #expect(!titles.contains("Clip"))
    }

    @Test("A studio window hides Tools and keeps Clip")
    func studioScope() throws {
        let titles = try visibleTopLevelTitles(for: .studio)
        #expect(titles.contains("Clip"))
        #expect(!titles.contains("Tools"))
    }

    @Test("With no editor window key, everything shows")
    func noScope() throws {
        let titles = try visibleTopLevelTitles(for: nil)
        #expect(titles.contains("Clip"))
        #expect(titles.contains("Tools"))
    }
}
