import Foundation

/// Temporary wallpaper shown while a capture overlay is up (docs/03 §7).
public enum CaptureWallpaper: String, CaseIterable, SettingValue {
    case none
    case black
    case gray
    case white
    case customImage

    public var title: String {
        switch self {
        case .none: String(localized: "Keep my wallpaper", bundle: .module)
        case .black: String(localized: "Solid black", bundle: .module)
        case .gray: String(localized: "Solid gray", bundle: .module)
        case .white: String(localized: "Solid white", bundle: .module)
        case .customImage: String(localized: "Custom image", bundle: .module)
        }
    }
}

public extension SettingKeys {
    /// Hide Finder icons and desktop widgets for as long as the user leaves the toggle on.
    static let desktopIconsHidden = SettingKey("desktop.iconsHidden", default: false)
    /// Hide icons automatically while the selection overlay or a still capture is running.
    static let hideDesktopDuringCapture = SettingKey("desktop.hideDuringCapture", default: false)
    /// Hide icons automatically for the duration of a recording.
    static let hideDesktopDuringRecording = SettingKey("desktop.hideDuringRecording", default: false)
    static let captureWallpaper = SettingKey("desktop.captureWallpaper", default: CaptureWallpaper.none)
    static let captureWallpaperImagePath = SettingKey("desktop.captureWallpaperImagePath", default: "")
    /// Full-screen crosshair guides + coordinates on the selection overlay (docs/03 §7).
    static let capturePrecisionCrosshair = SettingKey("capture.precisionCrosshair", default: false)
}
