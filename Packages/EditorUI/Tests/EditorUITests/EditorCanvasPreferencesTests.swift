import Foundation
import Testing
@testable import EditorUI

@Suite("Editor canvas preferences")
struct EditorCanvasPreferencesTests {
    @Test("The editor reads the shared lock-by-default key")
    func lockByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "EditorCanvasPreferencesTests"))
        defaults.removePersistentDomain(forName: "EditorCanvasPreferencesTests")
        defer { defaults.removePersistentDomain(forName: "EditorCanvasPreferencesTests") }

        #expect(!EditorCanvasPreferences.lockCanvasByDefault(defaults: defaults))

        defaults.set(true, forKey: EditorCanvasPreferences.lockCanvasByDefaultKey)
        #expect(EditorCanvasPreferences.lockCanvasByDefault(defaults: defaults))
    }

    @Test("The editor reads the shared object-shadow key")
    func objectShadows() throws {
        let defaults = try #require(UserDefaults(suiteName: "EditorCanvasPreferencesTests-shadow"))
        defaults.removePersistentDomain(forName: "EditorCanvasPreferencesTests-shadow")
        defer { defaults.removePersistentDomain(forName: "EditorCanvasPreferencesTests-shadow") }

        #expect(EditorCanvasPreferences.objectShadowsEnabled(defaults: defaults))

        defaults.set(false, forKey: EditorCanvasPreferences.objectShadowsEnabledKey)
        #expect(!EditorCanvasPreferences.objectShadowsEnabled(defaults: defaults))
    }

    @Test("Keep original defaults on and changes the flattened save stem")
    func keepOriginal() throws {
        let defaults = try #require(UserDefaults(suiteName: "EditorCanvasPreferencesTests-keep"))
        defaults.removePersistentDomain(forName: "EditorCanvasPreferencesTests-keep")
        defer { defaults.removePersistentDomain(forName: "EditorCanvasPreferencesTests-keep") }

        let url = URL(fileURLWithPath: "/tmp/Kadr-shot.png")
        #expect(EditorCanvasPreferences.keepOriginalWhenAnnotating(defaults: defaults))
        #expect(
            EditorCanvasPreferences.flattenedSaveStem(for: url, keepOriginal: true) == "Kadr-shot annotated"
        )
        #expect(EditorCanvasPreferences.flattenedSaveStem(for: url, keepOriginal: false) == "Kadr-shot")

        defaults.set(false, forKey: EditorCanvasPreferences.keepOriginalWhenAnnotatingKey)
        #expect(!EditorCanvasPreferences.keepOriginalWhenAnnotating(defaults: defaults))
    }
}
