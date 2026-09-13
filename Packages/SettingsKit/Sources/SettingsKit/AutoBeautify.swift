import Foundation

/// A built-in look applied to new stills, skipped when Shift is held at hotkey time
/// (CleanShot §9, docs/03 §3 P2).
///
/// Specs live in AnnotationModel; SettingsKit only stores which look was chosen so the
/// layering stays one-way.
public enum AutoBeautifyPreset: String, CaseIterable, SettingValue {
    case off
    case cleanWhite
    case twitter
    case instagram
    case story
    case stuckBottom

    public var title: String {
        switch self {
        case .off: "Off"
        case .cleanWhite: "Clean White"
        case .twitter: "Twitter / X"
        case .instagram: "Instagram"
        case .story: "Story"
        case .stuckBottom: "Edge Bleed"
        }
    }
}

public extension SettingKeys {
    static let autoBeautifyPreset = SettingKey(
        "capture.autoBeautifyPreset",
        default: AutoBeautifyPreset.off
    )
}
