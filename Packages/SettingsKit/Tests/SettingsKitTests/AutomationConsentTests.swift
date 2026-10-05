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
        #expect(!AutomationConsent(store: store()).allowsOtherApps)
    }

    @Test("Answers persist, and forgetting asks again")
    func persistence() {
        let defaults = store()
        let consent = AutomationConsent(store: defaults)
        consent.allowsOtherApps = true
        consent.record(.allowed, for: Self.raycast)

        let reloaded = AutomationConsent(store: defaults)
        #expect(reloaded.allowsOtherApps)
        #expect(reloaded.verdict(for: Self.raycast) == .run)
        #expect(reloaded.rememberedApps.map(\.name) == ["Raycast"])

        reloaded.forget(Self.key)
        #expect(reloaded.verdict(for: Self.raycast) == .ask)
    }

    @Test("An unidentified sender's answer is never remembered")
    func unidentifiedIsNotRemembered() {
        let consent = AutomationConsent(store: store())
        consent.allowsOtherApps = true
        consent.record(.allowed, for: .unidentified(name: "open"))
        #expect(consent.decisions.isEmpty)
    }

    @Test("Reset turns the switch off and forgets every app")
    func reset() {
        let defaults = store()
        let consent = AutomationConsent(store: defaults)
        consent.allowsOtherApps = true
        consent.record(.allowed, for: Self.raycast)

        consent.reset()

        #expect(!consent.allowsOtherApps)
        #expect(consent.rememberedApps.isEmpty)
        let reloaded = AutomationConsent(store: defaults)
        #expect(!reloaded.allowsOtherApps)
        #expect(reloaded.rememberedApps.isEmpty)
    }
}
