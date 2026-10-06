import Foundation
import Testing
@testable import Kadr

/// The automatic-update switch survives Kadr turning Sparkle's own scheduler off
/// (PRD §9, docs/10 R2.3).
///
/// The bug: Kadr writes `SUEnableAutomaticChecks = false` every launch, and the preference
/// fell back to that key while its own was unset — so from the second launch, everyone who
/// had never touched the switch silently lost automatic checks.
@MainActor
@Suite("Update check preference")
struct UpdateCheckPreferenceTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "com.bohdanbodnarenko.kadr.tests.updates.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create a defaults suite for the test")
        }
        return (defaults, suite)
    }

    /// What is stored before the preference is read, and what it should say.
    struct StoredState: Sendable, CustomTestStringConvertible {
        let kadr: Bool?
        let sparkle: Bool?
        let expected: Bool

        var testDescription: String {
            "Kadr \(String(describing: kadr)), Sparkle \(String(describing: sparkle))"
        }
    }

    @Test("The preference resolves from what is stored, never from Sparkle's key", arguments: [
        StoredState(kadr: nil, sparkle: nil, expected: true),
        StoredState(kadr: nil, sparkle: false, expected: true),
        StoredState(kadr: nil, sparkle: true, expected: true),
        StoredState(kadr: true, sparkle: false, expected: true),
        StoredState(kadr: false, sparkle: nil, expected: false),
        StoredState(kadr: false, sparkle: true, expected: false)
    ])
    func resolves(state: StoredState) {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        if let stored = state.kadr {
            defaults.set(stored, forKey: UpdateCheckPreference.key)
        }
        if let sparkle = state.sparkle {
            defaults.set(sparkle, forKey: UpdateCheckPreference.sparkleKey)
        }
        #expect(UpdateCheckPreference(defaults: defaults).isEnabled == state.expected)
    }

    /// The sequence that broke: first launch, Sparkle's timer is disabled, second launch.
    @Test("Disabling Sparkle's timer does not turn automatic checks off at the next launch")
    func survivesSparkleBeingDisabled() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstLaunch = UpdateCheckPreference(defaults: defaults)
        firstLaunch.migrateIfNeeded()
        defaults.set(false, forKey: UpdateCheckPreference.sparkleKey)

        let secondLaunch = UpdateCheckPreference(defaults: defaults)
        #expect(secondLaunch.isEnabled)
        #expect(defaults.object(forKey: UpdateCheckPreference.key) as? Bool == true)
    }

    @Test("Migration writes the default once and never overwrites a choice")
    func migrationIsOneShot() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = UpdateCheckPreference(defaults: defaults)

        #expect(defaults.object(forKey: UpdateCheckPreference.key) == nil)
        preference.migrateIfNeeded()
        #expect(defaults.object(forKey: UpdateCheckPreference.key) as? Bool == true)

        preference.isEnabled = false
        preference.migrateIfNeeded()
        #expect(!preference.isEnabled)
    }
}
