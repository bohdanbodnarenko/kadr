import AnnotationModel
import Foundation
import Testing
@testable import AnnotationRender

@Suite("Object shadow policy")
struct ObjectShadowPolicyTests {
    @Test("Shadows are on by default")
    func enabledByDefault() throws {
        let suite = "ObjectShadowPolicyTests-default-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ObjectShadowPolicy.isEnabled(defaults: defaults))
    }

    @Test("A disabled preference suppresses shadow drawing")
    func disabledSuppressesShadow() throws {
        let store = try makeDefaults(enabled: false)
        defer { store.removePersistentDomain(forName: store.description) }

        let spec = ImageSpec(pngData: Data(), rect: .zero, hasShadow: true)
        #expect(!ObjectShadowPolicy.drawsShadow(for: spec, defaults: store))
        #expect(try ObjectShadowPolicy.drawsShadow(for: spec, defaults: makeDefaults(enabled: true)))
    }

    private func makeDefaults(enabled: Bool) throws -> UserDefaults {
        let suite = "ObjectShadowPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(enabled, forKey: ObjectShadowPolicy.userDefaultsKey)
        return defaults
    }
}
