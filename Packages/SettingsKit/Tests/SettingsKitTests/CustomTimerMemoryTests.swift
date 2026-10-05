import Foundation
import Testing
@testable import SettingsKit

/// docs/17 T-CAP-12: a typed timer value survives picking a preset.
@Suite("Custom timer memory")
@MainActor
struct CustomTimerMemoryTests {
    @Test("Picking a preset turns the custom value off but remembers it, across launches")
    func remembered() throws {
        let suite = "CustomTimerMemoryTests-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }

        let settings = AppSettings(store: store)
        settings.customTimerSeconds = 7
        settings.selectPresetTimer(.threeSeconds)

        #expect(settings.timerSeconds == 3)
        #expect(settings.rememberedCustomTimerSeconds == 7)
        #expect(AppSettings(store: store).rememberedCustomTimerSeconds == 7)
    }
}
