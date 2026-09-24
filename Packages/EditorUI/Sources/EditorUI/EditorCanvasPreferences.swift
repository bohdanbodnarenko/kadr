import Foundation
import SettingsKit

/// The agent's Settings the editor honours (CleanShot §21).
///
/// The agent writes these keys into its own domain; the editor is another app with another
/// domain, so every read goes through `SharedPreferences` (T-ED-3).
public enum EditorCanvasPreferences {
    public static let lockCanvasByDefaultKey = SettingKeys.lockCanvasByDefault.name
    public static let objectShadowsEnabledKey = SettingKeys.objectShadowsEnabled.name
    public static let keepOriginalWhenAnnotatingKey = SettingKeys.keepOriginalWhenAnnotating.name
    public static let writesSidecarOnSaveKey = SettingKeys.writesSidecarOnSave.name

    public static func lockCanvasByDefault(preferences: SharedPreferences = SharedPreferences()) -> Bool {
        preferences.lockCanvasByDefault
    }

    public static func objectShadowsEnabled(preferences: SharedPreferences = SharedPreferences()) -> Bool {
        preferences.objectShadowsEnabled
    }

    public static func keepOriginalWhenAnnotating(preferences: SharedPreferences = SharedPreferences()) -> Bool {
        preferences.keepOriginalWhenAnnotating
    }

    /// Whether ⌘S also writes a sibling `.kadr` so the capture stays re-editable (docs/16 ED-7).
    public static func writesSidecarOnSave(preferences: SharedPreferences = SharedPreferences()) -> Bool {
        preferences.writesSidecarOnSave
    }

    /// Whether exports are converted to sRGB (the agent's General pane).
    public static func convertsExportsToSRGB(preferences: SharedPreferences = SharedPreferences()) -> Bool {
        preferences.convertExportsToSRGB
    }

    /// The filename stem for a flattened save next to `sourceURL`.
    public static func flattenedSaveStem(for sourceURL: URL, keepOriginal: Bool) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return keepOriginal ? "\(stem) annotated" : stem
    }
}
