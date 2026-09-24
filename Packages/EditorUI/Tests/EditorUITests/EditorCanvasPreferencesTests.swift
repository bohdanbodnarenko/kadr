import Foundation
import SettingsKit
import Testing
@testable import EditorUI

/// Written into a real preferences domain and read through `SharedPreferences`, the way
/// the agent and the editor meet in the product (T-ED-3).
@Suite("Editor canvas preferences")
struct EditorCanvasPreferencesTests {
    private func withDomain(_ body: (UserDefaults, SharedPreferences) -> Void) throws {
        let domain = "EditorCanvasPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        body(defaults, SharedPreferences(domain: domain))
    }

    @Test("The editor reads the agent's lock-by-default key")
    func lockByDefault() throws {
        try withDomain { defaults, preferences in
            #expect(!EditorCanvasPreferences.lockCanvasByDefault(preferences: preferences))
            defaults.set(true, forKey: EditorCanvasPreferences.lockCanvasByDefaultKey)
            defaults.synchronize()
            #expect(EditorCanvasPreferences.lockCanvasByDefault(preferences: preferences))
        }
    }

    @Test("The editor reads the agent's object-shadow key")
    func objectShadows() throws {
        try withDomain { defaults, preferences in
            #expect(EditorCanvasPreferences.objectShadowsEnabled(preferences: preferences))
            defaults.set(false, forKey: EditorCanvasPreferences.objectShadowsEnabledKey)
            defaults.synchronize()
            #expect(!EditorCanvasPreferences.objectShadowsEnabled(preferences: preferences))
        }
    }

    @Test("Keep original defaults on and changes the flattened save stem")
    func keepOriginal() throws {
        try withDomain { defaults, preferences in
            let url = URL(fileURLWithPath: "/tmp/Kadr-shot.png")
            #expect(EditorCanvasPreferences.keepOriginalWhenAnnotating(preferences: preferences))
            #expect(
                EditorCanvasPreferences.flattenedSaveStem(for: url, keepOriginal: true) == "Kadr-shot annotated"
            )
            #expect(EditorCanvasPreferences.flattenedSaveStem(for: url, keepOriginal: false) == "Kadr-shot")

            defaults.set(false, forKey: EditorCanvasPreferences.keepOriginalWhenAnnotatingKey)
            defaults.synchronize()
            #expect(!EditorCanvasPreferences.keepOriginalWhenAnnotating(preferences: preferences))
        }
    }

    @Test("The sidecar and sRGB flags come from the agent too")
    func sidecarAndSRGB() throws {
        try withDomain { defaults, preferences in
            #expect(EditorCanvasPreferences.writesSidecarOnSave(preferences: preferences))
            #expect(!EditorCanvasPreferences.convertsExportsToSRGB(preferences: preferences))
            defaults.set(false, forKey: EditorCanvasPreferences.writesSidecarOnSaveKey)
            defaults.set(true, forKey: SettingKeys.convertExportsToSRGB.name)
            defaults.synchronize()
            #expect(!EditorCanvasPreferences.writesSidecarOnSave(preferences: preferences))
            #expect(EditorCanvasPreferences.convertsExportsToSRGB(preferences: preferences))
        }
    }
}
