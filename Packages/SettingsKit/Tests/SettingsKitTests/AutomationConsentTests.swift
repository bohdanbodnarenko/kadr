import Foundation
import SettingsKit
import Testing

@MainActor
@Suite("Automation consent")
struct AutomationConsentTests {
    private func store() -> UserDefaults {
        let suite = "kadr-consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func consent(
        _ storage: InMemoryConsentStorage = InMemoryConsentStorage(),
        legacy: UserDefaults? = nil
    ) -> AutomationConsent {
        AutomationConsent(storage: storage, legacy: legacy ?? store())
    }

    private nonisolated static let raycast = AutomationConsent.Sender.app(
        bundleID: "com.raycast.macos",
        teamID: "SY64MV22J9",
        name: "Raycast"
    )
    private nonisolated static let key = AutomationConsent.key(for: raycast) ?? ""

    nonisolated struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let sender: AutomationConsent.Sender
        let allowsOtherApps: Bool
        let decisions: [String: AutomationConsent.Decision]
        let expected: AutomationConsent.Verdict

        var testDescription: String {
            name
        }
    }

    nonisolated static let rows: [Row] = [
        Row(name: "Kadr itself, switch off", sender: .kadr, allowsOtherApps: false, decisions: [:], expected: .run),
        Row(
            name: "an app, switch off",
            sender: raycast,
            allowsOtherApps: false,
            decisions: [:],
            expected: .refuse(.notAllowed)
        ),
        Row(
            name: "an allowed app, switch off",
            sender: raycast,
            allowsOtherApps: false,
            decisions: [key: .allowed],
            expected: .refuse(.notAllowed)
        ),
        Row(name: "a new app", sender: raycast, allowsOtherApps: true, decisions: [:], expected: .ask),
        Row(name: "an allowed app", sender: raycast, allowsOtherApps: true, decisions: [key: .allowed], expected: .run),
        Row(
            name: "a denied app",
            sender: raycast,
            allowsOtherApps: true,
            decisions: [key: .denied],
            expected: .refuse(.deniedBefore)
        ),
        Row(
            name: "an impostor with the same bundle ID",
            sender: .app(bundleID: "com.raycast.macos", teamID: nil, name: "Raycast"),
            allowsOtherApps: true,
            decisions: [key: .allowed],
            expected: .ask
        ),
        Row(
            name: "an unidentified sender",
            sender: .unidentified(name: "open"),
            allowsOtherApps: true,
            decisions: [:],
            expected: .ask
        )
    ]

    @Test("The policy table", arguments: rows)
    func policy(row: Row) {
        let verdict = AutomationConsent.verdict(
            for: row.sender,
            allowsOtherApps: row.allowsOtherApps,
            decisions: row.decisions
        )
        #expect(verdict == row.expected)
    }

    @Test("Off by default")
    func offByDefault() {
        #expect(!consent().allowsOtherApps)
    }

    @Test("Answers persist, and forgetting asks again")
    func persistence() {
        let storage = InMemoryConsentStorage()
        let first = consent(storage)
        first.allowsOtherApps = true
        first.record(.allowed, for: Self.raycast)

        let reloaded = consent(storage)
        #expect(reloaded.allowsOtherApps)
        #expect(reloaded.verdict(for: Self.raycast) == .run)
        #expect(reloaded.rememberedApps.map(\.name) == ["Raycast"])

        reloaded.forget(Self.key)
        #expect(reloaded.verdict(for: Self.raycast) == .ask)
    }

    @Test("An unidentified sender's answer is never remembered")
    func unidentifiedIsNotRemembered() {
        let gate = consent()
        gate.allowsOtherApps = true
        gate.record(.allowed, for: .unidentified(name: "open"))
        #expect(gate.decisions.isEmpty)
    }

    // MARK: - docs/18 OUT-13

    @Test("A browser is asked every time, and its answer is never kept")
    func browsersAreNeverRemembered() {
        let safari = AutomationConsent.Sender.app(bundleID: "com.apple.Safari", teamID: "APPLE", name: "Safari")
        let gate = consent()
        gate.allowsOtherApps = true
        gate.record(.allowed, for: safari)
        #expect(gate.decisions.isEmpty)
        #expect(gate.verdict(for: safari) == .ask)
        #expect(!gate.remembersAnswer(for: safari))
    }

    @Test("Upgrading keeps the switch and denials, and drops allows anything could have written")
    func legacyMigration() {
        let legacy = store()
        let denied = AutomationConsent.Sender.app(bundleID: "com.example.bad", teamID: "T", name: "Bad")
        let deniedKey = AutomationConsent.key(for: denied) ?? ""
        legacy.set(true, forKey: "automation.allowsOtherApps")
        legacy.set([Self.key: "allowed", deniedKey: "denied"], forKey: "automation.consentDecisions")
        legacy.set([Self.key: "Raycast", deniedKey: "Bad"], forKey: "automation.consentNames")

        let storage = InMemoryConsentStorage()
        let gate = consent(storage, legacy: legacy)

        #expect(gate.allowsOtherApps)
        #expect(gate.verdict(for: Self.raycast) == .ask, "a legacy allow is asked again")
        #expect(gate.verdict(for: denied) == .refuse(.deniedBefore))
        #expect(legacy.object(forKey: "automation.consentDecisions") == nil, "the old copy is gone")
        #expect(storage.snapshot?.decisions == [deniedKey: .denied])
    }

    @Test("Values written to the preferences domain later grant nothing")
    func defaultsCannotGrant() {
        let legacy = store()
        let storage = InMemoryConsentStorage(AutomationConsentSnapshot())
        legacy.set(true, forKey: "automation.allowsOtherApps")
        legacy.set([Self.key: "allowed"], forKey: "automation.consentDecisions")

        let gate = consent(storage, legacy: legacy)
        #expect(gate.verdict(for: Self.raycast) == .refuse(.notAllowed))
    }

    @Test("Reset forgets everything and turns the switch off")
    func reset() {
        let gate = consent()
        gate.allowsOtherApps = true
        gate.record(.allowed, for: Self.raycast)
        gate.reset()
        #expect(!gate.allowsOtherApps)
        #expect(gate.decisions.isEmpty)
    }
}
