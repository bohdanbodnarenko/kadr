import Foundation

/// What sits behind a captured window when it is not left transparent (docs/03 §1.2).
///
/// Applied after ScreenCaptureKit returns the window with its own alpha, so rounded
/// corners and the shadow show against the chosen fill rather than SCK's opaque plate.
public enum WindowBackdrop: String, CaseIterable, SettingValue {
    case white
    case black
    case gray
    case desktop
    case custom

    public var title: String {
        switch self {
        case .white: "White"
        case .black: "Black"
        case .gray: "Grey"
        case .desktop: "Desktop wallpaper"
        case .custom: "Custom image"
        }
    }

    public var isSolid: Bool {
        switch self {
        case .white, .black, .gray: true
        case .desktop, .custom: false
        }
    }
}

public extension SettingKeys {
    static let windowBackdrop = SettingKey("capture.windowBackdrop", default: WindowBackdrop.white)
    static let windowBackdropImagePath = SettingKey("capture.windowBackdropImagePath", default: "")
    /// Padding around a composited window, in points (CleanShot §10).
    static let windowBackdropPadding = SettingKey("capture.windowBackdropPadding", default: 40)
}
