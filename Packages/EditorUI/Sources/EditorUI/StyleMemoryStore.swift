import AnnotationModel
import Foundation

/// Persists last-used annotation styles across editor sessions (docs/03 §3, docs/16 ED-6).
///
/// Stored in `UserDefaults` like `EditorUserPalette`. EditorUI must not import SettingsKit
/// (docs/04 §2).
public enum StyleMemoryStore {
    public static let defaultsKey = "com.bohdanbodnarenko.kadr.editor.styleMemory"

    public static func load(from defaults: UserDefaults = .standard) -> StyleMemory {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(StyleMemory.self, from: data)
        else {
            return StyleMemory()
        }
        return decoded
    }

    public static func save(_ memory: StyleMemory, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
