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

/// The typed key set. Names are namespaced so `defaults read app.kadr.Kadr` stays legible.
public enum SettingKeys {
    public static let schemaVersion = SettingKey("settings.schemaVersion", default: 0)
    /// Whether the user has been through onboarding (docs/03 §8.2).
    public static let hasCompletedOnboarding = SettingKey("app.hasCompletedOnboarding", default: false)
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
    /// Keep the line structure of recognised text, or fold it into spaces (docs/03 §1.7).
    public static let ocrPreservesLineBreaks = SettingKey("capture.ocrPreservesLineBreaks", default: true)

    // Recording pane (docs/03 §1.8, §8.3).
    public static let recordingFrameRate = SettingKey("recording.frameRate", default: RecordingQuality.sixty)
    public static let recordingCodec = SettingKey("recording.codec", default: RecordingVideoCodec.hevc)
    public static let recordsSystemAudio = SettingKey("recording.systemAudio", default: true)
    public static let recordsMicrophone = SettingKey("recording.microphone", default: false)
    public static let recordingShowsCursor = SettingKey("recording.showsCursor", default: true)
    /// Turn on Do Not Disturb while recording, so notifications stay out of the file.
    public static let recordingEnablesFocus = SettingKey("recording.enablesFocus", default: true)
    /// Draw a halo where the user clicks (docs/03 §1.8).
    public static let recordingShowsClicks = SettingKey("recording.showsClicks", default: false)
    /// Show pressed keys. Off by default and shortcuts-only by default: showing every
    /// keystroke means showing whatever gets typed into a password field.
    public static let recordingShowsKeystrokes = SettingKey("recording.showsKeystrokes", default: false)
    public static let recordingKeystrokesShortcutsOnly = SettingKey(
        "recording.keystrokesShortcutsOnly",
        default: true
    )
    public static let recordingShowsWebcam = SettingKey("recording.showsWebcam", default: false)

    // MARK: Scrolling capture (docs/03 §1.6)

    /// Let Kadr do the scrolling. Off by default: it needs Accessibility, and the
    /// assisted tier needs no permission at all.
    public static let scrollAutoScroll = SettingKey("scroll.autoScroll", default: false)
    /// Points per synthesized scroll step. Smaller means more overlap and a safer stitch.
    public static let scrollStepPoints = SettingKey("scroll.stepPoints", default: 120)
    /// Frames a second while the user scrolls.
    public static let scrollFrameRate = SettingKey("scroll.frameRate", default: 8)
    /// Show the seam review when the stitch is not sure (docs/03 §1.6 failure mode).
    public static let scrollReviewsSeams = SettingKey("scroll.reviewsSeams", default: true)

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

    public var hasCompletedOnboarding: Bool {
        didSet { store[SettingKeys.hasCompletedOnboarding] = hasCompletedOnboarding }
    }

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

    public var ocrPreservesLineBreaks: Bool {
        didSet { store[SettingKeys.ocrPreservesLineBreaks] = ocrPreservesLineBreaks }
    }

    public var recordingFrameRate: RecordingQuality {
        didSet { store[SettingKeys.recordingFrameRate] = recordingFrameRate }
    }

    public var recordingCodec: RecordingVideoCodec {
        didSet { store[SettingKeys.recordingCodec] = recordingCodec }
    }

    public var recordsSystemAudio: Bool {
        didSet { store[SettingKeys.recordsSystemAudio] = recordsSystemAudio }
    }

    public var recordsMicrophone: Bool {
        didSet { store[SettingKeys.recordsMicrophone] = recordsMicrophone }
    }

    public var recordingShowsCursor: Bool {
        didSet { store[SettingKeys.recordingShowsCursor] = recordingShowsCursor }
    }

    public var recordingEnablesFocus: Bool {
        didSet { store[SettingKeys.recordingEnablesFocus] = recordingEnablesFocus }
    }

    public var recordingShowsClicks: Bool {
        didSet { store[SettingKeys.recordingShowsClicks] = recordingShowsClicks }
    }

    public var recordingShowsKeystrokes: Bool {
        didSet { store[SettingKeys.recordingShowsKeystrokes] = recordingShowsKeystrokes }
    }

    public var recordingKeystrokesShortcutsOnly: Bool {
        didSet { store[SettingKeys.recordingKeystrokesShortcutsOnly] = recordingKeystrokesShortcutsOnly }
    }

    public var recordingShowsWebcam: Bool {
        didSet { store[SettingKeys.recordingShowsWebcam] = recordingShowsWebcam }
    }

    public var scrollAutoScroll: Bool {
        didSet { store[SettingKeys.scrollAutoScroll] = scrollAutoScroll }
    }

    public var scrollStepPoints: Int {
        didSet { store[SettingKeys.scrollStepPoints] = scrollStepPoints }
    }

    public var scrollFrameRate: Int {
        didSet { store[SettingKeys.scrollFrameRate] = scrollFrameRate }
    }

    public var scrollReviewsSeams: Bool {
        didSet { store[SettingKeys.scrollReviewsSeams] = scrollReviewsSeams }
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
        hasCompletedOnboarding = store[SettingKeys.hasCompletedOnboarding]
        defaultAction = store[SettingKeys.defaultAction]
        saveFolderPath = store[SettingKeys.saveFolderPath]
        filenameTemplate = store[SettingKeys.filenameTemplate]
        imageFormat = store[SettingKeys.imageFormat]
        downscaleRetinaCaptures = store[SettingKeys.downscaleRetinaCaptures]
        includesCursor = store[SettingKeys.includesCursor]
        windowShadow = store[SettingKeys.windowShadow]
        transparentWindowBackground = store[SettingKeys.transparentWindowBackground]
        ocrPreservesLineBreaks = store[SettingKeys.ocrPreservesLineBreaks]
        recordingFrameRate = store[SettingKeys.recordingFrameRate]
        recordingCodec = store[SettingKeys.recordingCodec]
        recordsSystemAudio = store[SettingKeys.recordsSystemAudio]
        recordsMicrophone = store[SettingKeys.recordsMicrophone]
        recordingShowsCursor = store[SettingKeys.recordingShowsCursor]
        recordingEnablesFocus = store[SettingKeys.recordingEnablesFocus]
        recordingShowsClicks = store[SettingKeys.recordingShowsClicks]
        recordingShowsKeystrokes = store[SettingKeys.recordingShowsKeystrokes]
        recordingKeystrokesShortcutsOnly = store[SettingKeys.recordingKeystrokesShortcutsOnly]
        recordingShowsWebcam = store[SettingKeys.recordingShowsWebcam]
        scrollAutoScroll = store[SettingKeys.scrollAutoScroll]
        scrollStepPoints = store[SettingKeys.scrollStepPoints]
        scrollFrameRate = store[SettingKeys.scrollFrameRate]
        scrollReviewsSeams = store[SettingKeys.scrollReviewsSeams]
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
        ocrPreservesLineBreaks = SettingKeys.ocrPreservesLineBreaks.defaultValue
        recordingFrameRate = SettingKeys.recordingFrameRate.defaultValue
        recordingCodec = SettingKeys.recordingCodec.defaultValue
        recordsSystemAudio = SettingKeys.recordsSystemAudio.defaultValue
        recordsMicrophone = SettingKeys.recordsMicrophone.defaultValue
        recordingShowsCursor = SettingKeys.recordingShowsCursor.defaultValue
        recordingEnablesFocus = SettingKeys.recordingEnablesFocus.defaultValue
        recordingShowsClicks = SettingKeys.recordingShowsClicks.defaultValue
        recordingShowsKeystrokes = SettingKeys.recordingShowsKeystrokes.defaultValue
        recordingKeystrokesShortcutsOnly = SettingKeys.recordingKeystrokesShortcutsOnly.defaultValue
        recordingShowsWebcam = SettingKeys.recordingShowsWebcam.defaultValue
        scrollAutoScroll = SettingKeys.scrollAutoScroll.defaultValue
        scrollStepPoints = SettingKeys.scrollStepPoints.defaultValue
        scrollFrameRate = SettingKeys.scrollFrameRate.defaultValue
        scrollReviewsSeams = SettingKeys.scrollReviewsSeams.defaultValue
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
