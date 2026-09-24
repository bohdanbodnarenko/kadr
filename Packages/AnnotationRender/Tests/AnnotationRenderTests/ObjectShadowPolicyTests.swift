import AnnotationModel
import Foundation
import SettingsKit
import Testing
@testable import AnnotationRender

/// Reads a real preferences domain written the way the agent writes it (T-ED-3).
@Suite("Object shadow policy")
struct ObjectShadowPolicyTests {
    @Test("Shadows are on by default")
    func enabledByDefault() {
        let domain = "ObjectShadowPolicyTests-default-\(UUID().uuidString)"
        #expect(ObjectShadowPolicy.isEnabled(preferences: SharedPreferences(domain: domain)))
    }

    @Test("A disabled preference suppresses shadow drawing")
    func disabledSuppressesShadow() throws {
        let spec = ImageSpec(pngData: Data(), rect: .zero, hasShadow: true)
        try withDomain(enabled: false) { preferences in
            #expect(!ObjectShadowPolicy.drawsShadow(for: spec, preferences: preferences))
        }
        try withDomain(enabled: true) { preferences in
            #expect(ObjectShadowPolicy.drawsShadow(for: spec, preferences: preferences))
        }
    }

    @Test("The policy reads the key the agent's Settings write")
    func keyMatchesSettings() {
        #expect(ObjectShadowPolicy.userDefaultsKey == "annotate.objectShadowsEnabled")
    }

    private func withDomain(enabled: Bool, _ body: (SharedPreferences) -> Void) throws {
        let domain = "ObjectShadowPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(enabled, forKey: ObjectShadowPolicy.userDefaultsKey)
        defaults.synchronize()
        body(SharedPreferences(domain: domain))
    }
}
