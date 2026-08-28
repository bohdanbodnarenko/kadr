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

    public init(
        action: CaptureAction? = nil,
        region: ScreenRect? = nil,
        delay: Int? = nil,
        includesCursor: Bool? = nil
    ) {
        self.action = action
        self.region = region
        self.delay = delay
        self.includesCursor = includesCursor
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

    public init(
        frameRate: Int? = nil,
        region: ScreenRect? = nil,
        recordsMicrophone: Bool? = nil,
        recordsSystemAudio: Bool? = nil
    ) {
        self.frameRate = frameRate
        self.region = region
        self.recordsMicrophone = recordsMicrophone
        self.recordsSystemAudio = recordsSystemAudio
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
    case pickColor
    case recordScreen(RecordOptions)
    case recordRegion(RecordOptions)
    case stopRecording
    case pin(FileTarget)
    case annotate(FileTarget)
    case addToHistory(FileTarget)
    case closeAllPins
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
        case .pickColor: .pickColor
        case .recordScreen: .recordScreen
        case .recordRegion: .recordRegion
        case .stopRecording: .stopRecording
        case .pin: .pin
        case .annotate: .annotate
        case .addToHistory: .addToHistory
        case .closeAllPins: .closeAllPins
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
             .captureText, .captureScrolling, .pickColor, .stopRecording:
            true
        default:
            false
        }
    }
}
