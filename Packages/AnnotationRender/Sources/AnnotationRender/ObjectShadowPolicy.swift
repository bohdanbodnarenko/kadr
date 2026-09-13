import AnnotationModel
import Foundation

/// Whether inserted images cast a drop shadow (CleanShot §8.2 / §21).
///
/// The agent writes this key from Settings; the editor and export renderer read it.
/// AnnotationRender cannot import SettingsKit (docs/04 §2).
public enum ObjectShadowPolicy {
    public static let userDefaultsKey = "annotate.objectShadowsEnabled"

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: userDefaultsKey) as? Bool ?? true
    }

    public static func drawsShadow(for spec: ImageSpec, defaults: UserDefaults = .standard) -> Bool {
        spec.hasShadow && isEnabled(defaults: defaults)
    }
}
