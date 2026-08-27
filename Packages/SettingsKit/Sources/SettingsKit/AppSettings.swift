import Foundation
import Shared

/// What Kadr does with a capture the moment it is taken (docs/03 §8.3, §8.2).
public enum DefaultCaptureAction: String, CaseIterable, SettingValue {
    case copyToClipboard
    case saveToFolder
    case openInEditor

    public var title: String {
        switch self {
        case .copyToClipboard: "Copy to Clipboard"
        case .saveToFolder: "Save to Folder"
        case .openInEditor: "Open in Editor"
        }
    }
}

/// Still-image export formats (docs/03 §8.3, PRD §5 Phase 1).
public enum ImageFormat: String, CaseIterable, SettingValue {
    case png
    case jpeg
    case heic
    case webp

    public var fileExtension: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .webp: "WebP"
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

extension SelfTimer: SettingValue {
    public static func read(from defaults: UserDefaults, forKey key: String) -> SelfTimer? {
        guard let raw = defaults.object(forKey: key) as? Int else { return nil }
        return SelfTimer(rawValue: raw)
    }

    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(rawValue, forKey: key)
    }
}

/// The typed key set. Names are namespaced so `defaults read app.kadr.Kadr` stays legible.
public enum SettingKeys {
    public static let schemaVersion = SettingKey("settings.schemaVersion", default: 0)
    public static let defaultAction = SettingKey("general.defaultAction", default: DefaultCaptureAction.copyToClipboard)
    public static let saveFolderPath = SettingKey("general.saveFolderPath", default: "")
    public static let filenameTemplate = SettingKey("general.filenameTemplate", default: "{app}-{date}-{time}")
    public static let imageFormat = SettingKey("general.imageFormat", default: ImageFormat.png)
    public static let downscaleRetinaCaptures = SettingKey("general.downscaleRetinaCaptures", default: false)

    // Capture pane (docs/03 §8.3).
    public static let includesCursor = SettingKey("capture.includesCursor", default: false)
    public static let windowShadow = SettingKey("capture.windowShadow", default: true)
    public static let transparentWindowBackground = SettingKey("capture.transparentWindowBackground", default: true)
    /// Custom timer values live alongside the presets so a typed value survives a
    /// round-trip through the presets picker.
    public static let selfTimer = SettingKey("capture.selfTimer", default: SelfTimer.off)
    public static let customTimerSeconds = SettingKey("capture.customTimerSeconds", default: 0)
}

/// Observable façade over `UserDefaults` (docs/04 §9: plain `@Observable`, no TCA).
///
/// Properties write through on mutation, so a crash never loses a preference and
/// `defaults` on the command line always reflects the UI.
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let store: UserDefaults

    public var defaultAction: DefaultCaptureAction {
        didSet { store[SettingKeys.defaultAction] = defaultAction }
    }

    /// Empty means "not chosen yet"; reads resolve to the Desktop, like macOS screenshots.
    public var saveFolderPath: String {
        didSet { store[SettingKeys.saveFolderPath] = saveFolderPath }
    }

    public var filenameTemplate: String {
        didSet { store[SettingKeys.filenameTemplate] = filenameTemplate }
    }

    public var imageFormat: ImageFormat {
        didSet { store[SettingKeys.imageFormat] = imageFormat }
    }

    public var downscaleRetinaCaptures: Bool {
        didSet { store[SettingKeys.downscaleRetinaCaptures] = downscaleRetinaCaptures }
    }

    /// Draw the pointer into captures.
    public var includesCursor: Bool {
        didSet { store[SettingKeys.includesCursor] = includesCursor }
    }

    /// Keep a window's drop shadow when capturing it (docs/03 §1.2).
    public var windowShadow: Bool {
        didSet { store[SettingKeys.windowShadow] = windowShadow }
    }

    /// Preserve a window's own alpha instead of compositing it onto an opaque
    /// background, so rounded corners export as real transparency (docs/03 §1.2).
    public var transparentWindowBackground: Bool {
        didSet { store[SettingKeys.transparentWindowBackground] = transparentWindowBackground }
    }

    public var selfTimer: SelfTimer {
        didSet { store[SettingKeys.selfTimer] = selfTimer }
    }

    /// A typed timer value, used when it is longer than any preset. Zero means unused.
    public var customTimerSeconds: Int {
        didSet { store[SettingKeys.customTimerSeconds] = max(0, customTimerSeconds) }
    }

    /// How long a capture waits, taking the custom value into account (docs/03 §1.5).
    public var timerSeconds: Int {
        customTimerSeconds > 0 ? customTimerSeconds : selfTimer.seconds
    }

    public init(store: UserDefaults = .standard) {
        SettingsMigrator.migrate(store)
        self.store = store
        defaultAction = store[SettingKeys.defaultAction]
        saveFolderPath = store[SettingKeys.saveFolderPath]
        filenameTemplate = store[SettingKeys.filenameTemplate]
        imageFormat = store[SettingKeys.imageFormat]
        downscaleRetinaCaptures = store[SettingKeys.downscaleRetinaCaptures]
        includesCursor = store[SettingKeys.includesCursor]
        windowShadow = store[SettingKeys.windowShadow]
        transparentWindowBackground = store[SettingKeys.transparentWindowBackground]
        selfTimer = store[SettingKeys.selfTimer]
        customTimerSeconds = store[SettingKeys.customTimerSeconds]
    }

    /// Where captures are written. Falls back to the Desktop until the user picks a folder.
    public var saveFolder: URL {
        guard !saveFolderPath.isEmpty else { return Self.defaultSaveFolder }
        return URL(fileURLWithPath: saveFolderPath, isDirectory: true)
    }

    public static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Restores every key to its default. Used by Settings → Advanced → Reset (docs/03 §8.3).
    public func resetToDefaults() {
        defaultAction = SettingKeys.defaultAction.defaultValue
        saveFolderPath = SettingKeys.saveFolderPath.defaultValue
        filenameTemplate = SettingKeys.filenameTemplate.defaultValue
        imageFormat = SettingKeys.imageFormat.defaultValue
        downscaleRetinaCaptures = SettingKeys.downscaleRetinaCaptures.defaultValue
        includesCursor = SettingKeys.includesCursor.defaultValue
        windowShadow = SettingKeys.windowShadow.defaultValue
        transparentWindowBackground = SettingKeys.transparentWindowBackground.defaultValue
        selfTimer = SettingKeys.selfTimer.defaultValue
        customTimerSeconds = SettingKeys.customTimerSeconds.defaultValue
    }
}
