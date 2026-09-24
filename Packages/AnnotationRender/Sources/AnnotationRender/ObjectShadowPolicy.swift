import AnnotationModel
import Foundation
import SettingsKit

/// Whether inserted images cast a drop shadow (CleanShot §8.2 / §21).
///
/// The agent writes this key from Settings; the editor and export renderer read it from
/// the agent's domain, never their own (T-ED-3).
public enum ObjectShadowPolicy {
    public static func isEnabled(preferences: SharedPreferences = SharedPreferences()) -> Bool {
        preferences.objectShadowsEnabled
    }

    public static func drawsShadow(
        for spec: ImageSpec,
        preferences: SharedPreferences = SharedPreferences()
    ) -> Bool {
        spec.hasShadow && isEnabled(preferences: preferences)
    }
}
