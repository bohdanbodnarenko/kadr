import Foundation

/// Dark pill / light pill for on-screen captions (CleanShot keystroke overlay).
public enum OverlayChromeAppearance: String, Sendable, Hashable, Codable, CaseIterable {
    case dark
    case light

    public var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}
