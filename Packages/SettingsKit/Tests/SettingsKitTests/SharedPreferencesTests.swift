import Foundation
import Testing
@testable import SettingsKit

/// Uses a real preferences domain, written the way the agent writes it, because the bug
/// this guards (T-ED-3) passed every test that injected a `UserDefaults` suite.
@Suite("Shared preferences", .serialized)
struct SharedPreferencesTests {
    private static func withDomain(_ body: (String, UserDefaults) throws -> Void) throws {
        let domain = "app.kadr.Kadr.SharedPreferencesTests.\(UUID().uuidString)"
        let writer = try #require(UserDefaults(suiteName: domain))
        defer { writer.removePersistentDomain(forName: domain) }
        try body(domain, writer)
    }

    @Test("The agent domain is the agent's bundle identifier")
    func agentDomain() {
        #expect(SharedPreferences.agentDomain == "app.kadr.Kadr")
        #expect(SharedPreferences().domain == "app.kadr.Kadr")
    }

    @Test(
        "A missing key reads as the key's default",
        arguments: [
            (SettingKeys.lockCanvasByDefault, false),
            (SettingKeys.objectShadowsEnabled, true),
            (SettingKeys.keepOriginalWhenAnnotating, true),
            (SettingKeys.writesSidecarOnSave, true),
            (SettingKeys.convertExportsToSRGB, false)
        ]
    )
    func defaults(key: SettingKey<Bool>, expected: Bool) throws {
        try Self.withDomain { domain, _ in
            #expect(SharedPreferences(domain: domain)[key] == expected)
        }
    }

    @Test("A value the agent wrote is read from another domain's process view")
    func readsWrittenValues() throws {
        try Self.withDomain { domain, writer in
            writer[SettingKeys.lockCanvasByDefault] = true
            writer[SettingKeys.objectShadowsEnabled] = false
            writer[SettingKeys.keepOriginalWhenAnnotating] = false
            writer[SettingKeys.writesSidecarOnSave] = false
            writer[SettingKeys.convertExportsToSRGB] = true
            writer.synchronize()

            let shared = SharedPreferences(domain: domain)
            #expect(shared.lockCanvasByDefault)
            #expect(!shared.objectShadowsEnabled)
            #expect(!shared.keepOriginalWhenAnnotating)
            #expect(!shared.writesSidecarOnSave)
            #expect(shared.convertExportsToSRGB)
        }
    }

    @Test("A value of the wrong type falls back to the default")
    func wrongType() throws {
        try Self.withDomain { domain, writer in
            writer.set("yes", forKey: SettingKeys.objectShadowsEnabled.name)
            writer.synchronize()
            #expect(SharedPreferences(domain: domain).objectShadowsEnabled)
        }
    }
}
