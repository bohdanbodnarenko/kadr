import Foundation
import Shared

/// What Kadr should do with a capture the automation layer asked for (docs/03 §8.4).
///
/// `nil` anywhere this appears means "whatever the user chose in Settings" — an
/// automation that does not say is not overriding a preference.
public enum CaptureAction: String, Codable, Sendable, CaseIterable, Hashable {
    case copy
    case save
    case annotate
    case pin
    /// Stage the capture and show the card, writing nothing to the save folder yet.
    case overlay
}

/// A capture verb's parameters (docs/03 §8.4).
public struct CaptureOptions: Codable, Hashable, Sendable {
    public var action: CaptureAction?
    /// A region in global screen points, so a script can re-capture a known rectangle
    /// without the selection overlay. Partial rectangles are a parse error, never a guess.
    public var region: ScreenRect?
    /// Self-timer override, in seconds. `nil` uses the Settings value.
    public var delay: Int?
    /// Draw the pointer into the capture. `nil` uses the Settings value.
    public var includesCursor: Bool?
    /// Keep line breaks in recognised text. `nil` uses the Settings value.
    public var preservesLineBreaks: Bool?
    /// CleanShot-style 1-based display index (`1` is the primary display). When set,
    /// `region` is local to that display's bottom-left rather than global screen space.
    public var display: Int?
    /// OCR an existing image instead of selecting a region (CleanShot §20.6 `filepath=`).
    public var path: String?
    /// Scrolling capture: let Kadr do the scrolling (CleanShot §20.3 `autoscroll=`).
    public var autoScroll: Bool?
    /// Scrolling capture: with a region, start frame capture immediately (CleanShot §20.3
    /// `start=`). `false` shows the selection overlay even when `x,y,width,height` are set.
    public var startsImmediately: Bool?

    public init(
        action: CaptureAction? = nil,
        region: ScreenRect? = nil,
        delay: Int? = nil,
        includesCursor: Bool? = nil,
        preservesLineBreaks: Bool? = nil,
        display: Int? = nil,
        path: String? = nil,
        autoScroll: Bool? = nil,
        startsImmediately: Bool? = nil
    ) {
        self.action = action
        self.region = region
        self.delay = delay
        self.includesCursor = includesCursor
        self.preservesLineBreaks = preservesLineBreaks
        self.display = display
        self.path = path
        self.autoScroll = autoScroll
        self.startsImmediately = startsImmediately
    }

    public static let none = CaptureOptions()
}

/// A recording verb's parameters (docs/03 §8.4).
public struct RecordOptions: Codable, Hashable, Sendable {
    /// Frames a second. `nil` uses the Settings value.
    public var frameRate: Int?
    public var region: ScreenRect?
    public var recordsMicrophone: Bool?
    public var recordsSystemAudio: Bool?
    /// CleanShot-style 1-based display index (`1` is the primary display).
    public var display: Int?
    /// After the recording stops, encode a GIF rather than leaving an MP4 card
    /// (CleanShot §13.6, docs/03 §1.8). `nil` / `false` keep the video card.
    public var exportAsGIF: Bool?

    public init(
        frameRate: Int? = nil,
        region: ScreenRect? = nil,
        recordsMicrophone: Bool? = nil,
        recordsSystemAudio: Bool? = nil,
        display: Int? = nil,
        exportAsGIF: Bool? = nil
    ) {
        self.frameRate = frameRate
        self.region = region
        self.recordsMicrophone = recordsMicrophone
        self.recordsSystemAudio = recordsSystemAudio
        self.display = display
        self.exportAsGIF = exportAsGIF
    }

    public static let none = RecordOptions()
}

/// A verb that names a file on disk (pin, annotate).
public struct FileTarget: Codable, Hashable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }

    public var url: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

/// Three-state switches, so a script can set a state rather than only flip it.
public enum ToggleState: String, Codable, Sendable, CaseIterable, Hashable {
    case on
    case off
    case toggle
}

/// The Settings window's panes, addressable by name (docs/03 §8.4 `open-settings?tab=`).
public enum SettingsTab: String, Codable, Sendable, CaseIterable, Hashable {
    case general
    case overlay
    case capture
    case recording
    case history
    case shortcuts
    case updates
    case advanced

    /// Accepts Kadr pane names and the CleanShot tab spellings a migrating script uses.
    public static func named(_ raw: String) -> SettingsTab? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let tab = SettingsTab(rawValue: key) {
            return tab
        }
        switch key {
        case "wallpaper", "screenshots", "annotate":
            return .capture
        case "quickaccess", "quick-access", "quickaccessoverlay":
            return .overlay
        case "about":
            return .updates
        default:
            return nil
        }
    }
}

/// Everything automation can ask the agent to do (docs/03 §8.4).
///
/// One value type shared by all three frontends — URL scheme, CLI and Shortcuts — so a
/// verb cannot exist in one and be missing from another, and so the routing in the agent
/// is written once. `Codable` because the CLI sends these to the agent as JSON.
public enum AppCommand: Codable, Hashable, Sendable {
    case captureArea(CaptureOptions)
    case captureWindow(CaptureOptions)
    case captureFullscreen(CaptureOptions)
    case capturePreviousArea(CaptureOptions)
    case captureText(CaptureOptions)
    case captureScrolling(CaptureOptions)
    case allInOne(CaptureOptions)
    case selfTimer(CaptureOptions)
    case pickColor
    case recordScreen(RecordOptions)
    case recordRegion(RecordOptions)
    case stopRecording
    case pin(FileTarget?)
    case annotate(FileTarget)
    case addToHistory(FileTarget)
    case addQuickAccessOverlay(FileTarget)
    case openFromClipboard
    case closeAllPins
    case closeAllOverlays
    case saveAllOverlays
    case hideOverlays
    case hidePins
    case restoreRecentlyClosed
    case toggleDesktopIcons(ToggleState)
    case freezeScreen
    case openHistory
    case openSettings(SettingsTab?)
    case version

    /// The canonical verb this command came from, and the one it round-trips to.
    public var verb: AutomationVerb {
        switch self {
        case .captureArea: .captureArea
        case .captureWindow: .captureWindow
        case .captureFullscreen: .captureFullscreen
        case .capturePreviousArea: .capturePreviousArea
        case .captureText: .captureText
        case .captureScrolling: .captureScrolling
        case .allInOne: .allInOne
        case .selfTimer: .selfTimer
        case .pickColor: .pickColor
        case .recordScreen: .recordScreen
        case let .recordRegion(options): options.exportAsGIF == true ? .recordGif : .recordRegion
        case .stopRecording: .stopRecording
        case .pin: .pin
        case .annotate: .annotate
        case .addToHistory: .addToHistory
        case .addQuickAccessOverlay: .addQuickAccessOverlay
        case .openFromClipboard: .openFromClipboard
        case .closeAllPins: .closeAllPins
        case .closeAllOverlays: .closeAllOverlays
        case .saveAllOverlays: .saveAllOverlays
        case .hideOverlays: .hideOverlays
        case .hidePins: .hidePins
        case .restoreRecentlyClosed: .restoreRecentlyClosed
        case .toggleDesktopIcons: .toggleDesktopIcons
        case .freezeScreen: .freezeScreen
        case .openHistory: .openHistory
        case .openSettings: .openSettings
        case .version: .version
        }
    }

    /// Whether the caller should expect a file or some text back.
    ///
    /// The CLI waits for a result only for these; `open-settings` returning "ok" the
    /// moment the window opens is the right behaviour for a script. Starting a recording
    /// deliberately is *not* on the list — the file does not exist until the user stops,
    /// which could be an hour later, so `record-screen` returns as soon as it is rolling
    /// and `stop-recording` is what hands back the path.
    public var producesOutput: Bool {
        switch self {
        case .captureArea, .captureWindow, .captureFullscreen, .capturePreviousArea,
             .captureText, .captureScrolling, .selfTimer, .pickColor, .stopRecording:
            true
        case let .allInOne(options):
            options.region != nil
        default:
            false
        }
    }
}
