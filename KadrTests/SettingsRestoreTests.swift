import AutomationKit
import Foundation
import Testing
@testable import Kadr

/// Settings reopens where the user left it (HIG › Settings, docs/17 T-SH-8).
@MainActor
@Suite("Settings restores the last pane")
struct SettingsRestoreTests {
    @Test("The stored pane, or General when there is none or it is unknown", arguments: [
        (String?.none, SettingsTab.general),
        ("shortcuts", .shortcuts),
        ("advanced", .advanced),
        ("no-such-pane", .general)
    ])
    func lastTab(stored: String?, expected: SettingsTab) throws {
        let suite = "kadr.tests.lastTab.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if let stored {
            defaults.set(stored, forKey: SettingsWindowController.lastTabKey)
        }
        #expect(SettingsWindowController.lastTab(in: defaults) == expected)
    }
}
