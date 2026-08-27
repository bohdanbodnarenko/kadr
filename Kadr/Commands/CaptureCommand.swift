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
    case capturePreviousArea

    /// Menu title (docs/03 §8.1).
    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureFullscreen: "Capture Screen"
        case .captureText: "Capture Text (OCR)"
        case .capturePreviousArea: "Capture Previous Area"
        }
    }

    /// Label for the Shortcuts settings pane.
    var shortcutTitle: String {
        title
    }

    /// Commands the menu offers directly. `capturePreviousArea` is a hotkey-only
    /// repeat of the last region, so it stays off the menu (docs/03 §8.1).
    static var menuCommands: [CaptureCommand] {
        [.captureArea, .captureWindow, .captureFullscreen, .captureText]
    }
}
