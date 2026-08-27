import Foundation

/// The commands a user can trigger from the menu bar or a global hotkey.
///
/// This is the vocabulary the status item and `HotkeyCenter` share, so a command
/// cannot appear in one and not the other. When AutomationKit gains URL-scheme and
/// CLI parsing (docs/03 §8.4, P2), it will produce these same values.
nonisolated enum CaptureCommand: String, CaseIterable, Sendable {
    case captureArea
    case captureWindow
    case captureFullscreen
    case captureText
    case captureScrolling
    case capturePreviousArea
    case recordRegion
    case recordDisplay
    case freezeScreen
    case toggleDesktopIcons

    /// Menu title (docs/03 §8.1).
    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureFullscreen: "Capture Screen"
        case .captureText: "Capture Text (OCR)"
        case .captureScrolling: "Scrolling Capture…"
        case .capturePreviousArea: "Capture Previous Area"
        case .recordRegion: "Record Region…"
        case .recordDisplay: "Record Screen"
        case .freezeScreen: "Freeze Screen"
        case .toggleDesktopIcons: "Hide Desktop Icons"
        }
    }

    /// Label for the Shortcuts settings pane.
    var shortcutTitle: String {
        switch self {
        case .toggleDesktopIcons: "Toggle Desktop Icons"
        default: title
        }
    }

    /// Whether the command does something yet.
    ///
    /// Menu items for unimplemented commands are shown but disabled, so the menu is an
    /// honest map of the app rather than a list that grows unpredictably.
    var isAvailable: Bool {
        true
    }

    /// Commands the menu offers directly. `capturePreviousArea` is a hotkey-only
    /// repeat of the last region, so it stays off the menu (docs/03 §8.1).
    static var menuCommands: [CaptureCommand] {
        [.captureArea, .captureWindow, .captureFullscreen, .captureScrolling, .captureText]
    }

    /// Freeze and desktop hygiene, grouped under the capture actions (docs/03 §7).
    static var utilityCommands: [CaptureCommand] {
        [.freezeScreen, .toggleDesktopIcons]
    }

    /// The recording commands, which the menu groups separately (docs/03 §1.8).
    static var recordingCommands: [CaptureCommand] {
        [.recordRegion, .recordDisplay]
    }
}
