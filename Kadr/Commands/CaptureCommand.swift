import Foundation

/// The commands a user can trigger from the menu bar or a global hotkey.
///
/// This is the vocabulary the status item and `HotkeyCenter` share, so a command
/// cannot appear in one and not the other. When AutomationKit gains URL-scheme and
/// CLI parsing (docs/03 §8.4, P2), it will produce these same values.
nonisolated enum CaptureCommand: String, CaseIterable, Sendable {
    case allInOne
    case captureArea
    case captureWindow
    case captureFullscreen
    case captureText
    case pickColor
    case captureScrolling
    case capturePreviousArea
    /// Area capture that copies, regardless of the after-capture matrix (CleanShot §2.6).
    case captureAreaAndCopy
    /// Area capture that saves, regardless of the after-capture matrix (CleanShot §2.6).
    case captureAreaAndSave
    /// Countdown, then area capture, so hover menus can be staged (docs/03 §1.5).
    case selfTimer
    case recordRegion
    case recordDisplay
    /// Ends whatever is recording (docs/03 §1.8).
    ///
    /// A command of its own as well as the toggle on the two record hotkeys, because the
    /// user who cannot remember which one they started with still needs a way out.
    case stopRecording
    /// Opens record mode rather than starting a recording (docs/03 §1.4).
    case recordSetup
    case freezeScreen
    case toggleDesktopIcons
    case closeAllOverlays
    case saveAllOverlays
    /// Hide overlay cards so they do not appear in the next capture (CleanShot §6.3).
    case hideOverlays
    /// Hide / show every pinned screenshot without closing them (CleanShot §11).
    case hidePins

    /// Menu title (docs/03 §8.1).
    var title: String {
        switch self {
        case .allInOne: "All-in-One"
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureFullscreen: "Capture Screen"
        case .captureText: "Capture Text (OCR)"
        case .pickColor: "Pick Colour…"
        case .captureScrolling: "Scrolling Capture…"
        case .capturePreviousArea: "Capture Previous Area"
        case .captureAreaAndCopy: "Capture Area and Copy"
        case .captureAreaAndSave: "Capture Area and Save"
        case .selfTimer: "Self-Timer"
        case .recordRegion: "Record Region…"
        case .recordDisplay: "Record Screen"
        case .stopRecording: "Stop Recording"
        case .recordSetup: "Record…"
        case .freezeScreen: "Freeze Screen"
        case .toggleDesktopIcons: "Hide Desktop Icons"
        case .closeAllOverlays: "Close All Overlays"
        case .saveAllOverlays: "Save All Overlays"
        case .hideOverlays: "Hide Overlays"
        case .hidePins: "Hide Pins"
        }
    }

    /// Label for the Shortcuts settings pane.
    var shortcutTitle: String {
        switch self {
        case .toggleDesktopIcons: "Toggle Desktop Icons"
        case .hideOverlays: "Hide / Show Overlays"
        case .hidePins: "Hide / Show Pins"
        default: title
        }
    }

    /// Commands the menu offers directly. Repeat-the-last-region and the capture-and-action
    /// family are hotkey-only, so they stay off the menu (docs/03 §8.1).
    static var menuCommands: [CaptureCommand] {
        [
            .allInOne,
            .captureArea,
            .captureWindow,
            .captureFullscreen,
            .captureScrolling,
            .captureText,
            .pickColor
        ]
    }

    /// Freeze and desktop hygiene, grouped under the capture actions (docs/03 §7).
    static var utilityCommands: [CaptureCommand] {
        [.selfTimer, .freezeScreen, .toggleDesktopIcons]
    }

    /// Overlay stack commands, grouped under History in the menu (CleanShot §6.3).
    static var overlayCommands: [CaptureCommand] {
        [.saveAllOverlays, .closeAllOverlays, .hideOverlays]
    }

    /// The recording commands, which the menu groups separately (docs/03 §1.8).
    static var recordingCommands: [CaptureCommand] {
        [.recordRegion, .recordDisplay]
    }
}
