import Foundation

/// Editor-only preferences stored in shared `UserDefaults` (CleanShot §21).
///
/// EditorUI cannot import SettingsKit (docs/04 §2), but both apps read the same keys
/// Kadr writes from Settings.
public enum EditorCanvasPreferences {
    public static let lockCanvasByDefaultKey = "annotate.lockCanvasByDefault"
    public static let objectShadowsEnabledKey = "annotate.objectShadowsEnabled"
    public static let keepOriginalWhenAnnotatingKey = "annotate.keepOriginalWhenAnnotating"

    public static func lockCanvasByDefault(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: lockCanvasByDefaultKey) as? Bool ?? false
    }

    public static func objectShadowsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: objectShadowsEnabledKey) as? Bool ?? true
    }

    public static func keepOriginalWhenAnnotating(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepOriginalWhenAnnotatingKey) as? Bool ?? true
    }

    /// The filename stem for a flattened save next to `sourceURL`.
    public static func flattenedSaveStem(for sourceURL: URL, keepOriginal: Bool) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return keepOriginal ? "\(stem) annotated" : stem
    }
}
