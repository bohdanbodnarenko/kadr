import Foundation
import Shared

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

    // Overlay pane (docs/03 §2, §8.3).
    public static let overlayCorner = SettingKey("overlay.corner", default: OverlayCorner.bottomLeft)
    public static let overlayCardWidth = SettingKey("overlay.cardWidth", default: 220)
    public static let overlayTimeout = SettingKey("overlay.timeout", default: OverlayTimeout.never)
    /// Cards visible before older ones collapse behind the stack (docs/03 §2).
    public static let overlayMaxVisibleCards = SettingKey("overlay.maxVisibleCards", default: 5)
    /// Always show cards on the primary display instead of the capture's display.
    public static let overlayOnPrimaryDisplay = SettingKey("overlay.onPrimaryDisplay", default: false)
    /// Remove the card when its file is dragged out (docs/03 §2).
    public static let overlayDismissOnDrag = SettingKey("overlay.dismissOnDrag", default: true)
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

    public var overlayCorner: OverlayCorner {
        didSet { store[SettingKeys.overlayCorner] = overlayCorner }
    }

    /// Card width in points, clamped so a stray value cannot produce an unusable card.
    ///
    /// Computed rather than stored with a `didSet`: assigning to a property inside its
    /// own observer crashes the `@Observable` macro's generated accessors, so clamping
    /// goes through the manual observation API instead.
    public var overlayCardWidth: Int {
        get {
            access(keyPath: \.overlayCardWidth)
            return Self.clamp(store[SettingKeys.overlayCardWidth], to: 140 ... 420)
        }
        set {
            withMutation(keyPath: \.overlayCardWidth) {
                store[SettingKeys.overlayCardWidth] = Self.clamp(newValue, to: 140 ... 420)
            }
        }
    }

    public var overlayTimeout: OverlayTimeout {
        didSet { store[SettingKeys.overlayTimeout] = overlayTimeout }
    }

    /// Cards shown before older ones collapse behind the stack (docs/03 §2).
    public var overlayMaxVisibleCards: Int {
        get {
            access(keyPath: \.overlayMaxVisibleCards)
            return Self.clamp(store[SettingKeys.overlayMaxVisibleCards], to: 1 ... 10)
        }
        set {
            withMutation(keyPath: \.overlayMaxVisibleCards) {
                store[SettingKeys.overlayMaxVisibleCards] = Self.clamp(newValue, to: 1 ... 10)
            }
        }
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    public var overlayOnPrimaryDisplay: Bool {
        didSet { store[SettingKeys.overlayOnPrimaryDisplay] = overlayOnPrimaryDisplay }
    }

    public var overlayDismissOnDrag: Bool {
        didSet { store[SettingKeys.overlayDismissOnDrag] = overlayDismissOnDrag }
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
        overlayCorner = store[SettingKeys.overlayCorner]
        overlayTimeout = store[SettingKeys.overlayTimeout]
        overlayOnPrimaryDisplay = store[SettingKeys.overlayOnPrimaryDisplay]
        overlayDismissOnDrag = store[SettingKeys.overlayDismissOnDrag]
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
        overlayCorner = SettingKeys.overlayCorner.defaultValue
        overlayCardWidth = SettingKeys.overlayCardWidth.defaultValue
        overlayTimeout = SettingKeys.overlayTimeout.defaultValue
        overlayMaxVisibleCards = SettingKeys.overlayMaxVisibleCards.defaultValue
        overlayOnPrimaryDisplay = SettingKeys.overlayOnPrimaryDisplay.defaultValue
        overlayDismissOnDrag = SettingKeys.overlayDismissOnDrag.defaultValue
    }
}
