import Foundation
import Shared

// The enumerations the settings are made of. Separated from `AppSettings` itself because
// they are values rather than state: nothing here observes anything, and the class had
// outgrown one file.

/// What Kadr does with a capture the moment it is taken (docs/03 §2, §8.3).
public enum DefaultCaptureAction: String, CaseIterable, SettingValue {
    case copyToClipboard
    case saveToFolder
    case copyAndSave
    /// Nothing is written to the save folder yet: the file waits in the staging area and
    /// is finalised on the first thing the user does with it, which keeps the Desktop
    /// clean (docs/03 §2).
    case overlayOnly

    public var title: String {
        switch self {
        case .copyToClipboard: "Copy to Clipboard"
        case .saveToFolder: "Save to Folder"
        case .copyAndSave: "Copy and Save"
        case .overlayOnly: "Keep in the Overlay Only"
        }
    }

    public var copiesToClipboard: Bool {
        self == .copyToClipboard || self == .copyAndSave
    }

    public var savesToFolder: Bool {
        self == .saveToFolder || self == .copyAndSave
    }
}

/// `ImageFormat` lives in Shared because the setting that picks it and the writer that
/// honours it are sibling packages that cannot import each other (docs/04 §2).
extension ImageFormat: SettingValue {}

/// Same story as `ImageFormat`: the setting and the capture engine that honours it are
/// sibling packages, so the type lives in Shared (docs/04 §2, docs/06 M25).
extension DynamicRange: SettingValue {}

/// `CompressedImageFormat` lives in Shared for the same reason `ImageFormat` does: the
/// setting that picks it and the encoder that honours it are sibling packages
/// (docs/04 §2, docs/09 U2.4).
extension CompressedImageFormat: SettingValue {}

extension ScrollAxis: SettingValue {
    public var title: String {
        switch self {
        case .vertical: "Vertical"
        case .horizontal: "Horizontal"
        }
    }
}

/// What a self-timer counts down before capturing (docs/03 §1.5).
public enum SelfTimer: Int, CaseIterable, Sendable {
    case off = 0
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10

    public var seconds: Int {
        rawValue
    }

    public var title: String {
        switch self {
        case .off: "Off"
        default: "\(rawValue) seconds"
        }
    }
}

extension SelfTimer: SettingValue {}

/// Where the Quick Access Overlay sits (docs/03 §2, §8.3).
public enum OverlayCorner: String, CaseIterable, SettingValue {
    case bottomLeft
    case bottomRight
    case topLeft
    case topRight

    public var title: String {
        switch self {
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        }
    }

    public var isLeading: Bool {
        self == .bottomLeft || self == .topLeft
    }

    public var isBottom: Bool {
        self == .bottomLeft || self == .bottomRight
    }
}

/// How long a card waits before dismissing itself (docs/03 §2).
public enum OverlayTimeout: Int, CaseIterable, SettingValue {
    /// Never — the default, because a card vanishing mid-drag is maddening.
    case never = 0
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30

    public var seconds: Int {
        rawValue
    }

    public var title: String {
        switch self {
        case .never: "Never"
        default: "After \(rawValue) seconds"
        }
    }
}

/// Recording settings (docs/03 §1.8). Mirrors `RecordingCore`'s own types as raw values,
/// because SettingsKit and RecordingCore are sibling packages that cannot import each
/// other (docs/04 §2) — the app maps between them.
public enum RecordingQuality: Int, CaseIterable, SettingValue {
    case twentyFour = 24
    case thirty = 30
    case sixty = 60

    public var title: String {
        "\(rawValue) fps"
    }
}

public enum RecordingVideoCodec: String, CaseIterable, SettingValue {
    case hevc
    case h264

    public var title: String {
        switch self {
        case .hevc: "HEVC (smaller files)"
        case .h264: "H.264 (most compatible)"
        }
    }
}
