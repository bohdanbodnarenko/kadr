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
    /// Pauses a running take, or resumes a paused one (docs/18 REC-11). No default key:
    /// a global shortcut is taken from every app, and only blind-fired commands get one.
    case pauseRecording
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
    /// Pin whatever is on the clipboard — an image, or text drawn as a card (docs/03 §4).
    case pinClipboard
    /// Turns click-through off (or on) for the pin under the pointer, or the newest one
    /// (docs/17 T-OUT-9). The way back out of a click-through pin, which cannot open its
    /// own menu.
    case togglePinClickThrough
    /// Opens the History window (docs/16 X-7).
    case openHistory
    /// Reveals the capture save folder in Finder (docs/16 X-7).
    case openSaveFolder

    /// Menu title (docs/03 §8.1).
    var title: String {
        switch self {
        case .allInOne: String(localized: "All-in-One")
        case .captureArea: String(localized: "Capture Area")
        case .captureWindow: String(localized: "Capture Window")
        case .captureFullscreen: String(localized: "Capture Screen")
        case .captureText: String(localized: "Capture Text (OCR)")
        case .pickColor: String(localized: "Pick Colour…")
        case .captureScrolling: String(localized: "Scrolling Capture…")
        case .capturePreviousArea: String(localized: "Capture Previous Area")
        case .captureAreaAndCopy: String(localized: "Capture Area and Copy")
        case .captureAreaAndSave: String(localized: "Capture Area and Save")
        case .selfTimer: String(localized: "Self-Timer")
        case .recordRegion: String(localized: "Record Region…")
        case .recordDisplay: String(localized: "Record Screen")
        case .stopRecording: String(localized: "Stop Recording")
        case .pauseRecording: String(localized: "Pause / Resume Recording")
        case .recordSetup: String(localized: "Record…")
        case .freezeScreen: String(localized: "Freeze Screen")
        case .toggleDesktopIcons: String(localized: "Hide Desktop Icons")
        case .closeAllOverlays: String(localized: "Close All Overlays")
        case .saveAllOverlays: String(localized: "Save All Overlays")
        case .hideOverlays: String(localized: "Hide Overlays")
        case .hidePins: String(localized: "Hide Pins")
        case .pinClipboard: String(localized: "Pin Clipboard")
        case .togglePinClickThrough: String(localized: "Toggle Pin Click-Through")
        case .openHistory: String(localized: "History…")
        case .openSaveFolder: String(localized: "Open Capture Folder")
        }
    }

    /// Label for the Shortcuts settings pane.
    var shortcutTitle: String {
        switch self {
        case .toggleDesktopIcons: "Toggle Desktop Icons"
        case .hideOverlays: "Hide / Show Overlays"
        case .hidePins: "Hide / Show Pins"
        case .pinClipboard: "Pin Clipboard"
        case .openHistory: "History"
        case .openSaveFolder: "Open Capture Folder"
        default: title
        }
    }

    /// The glyph the status menu draws beside this command, or `nil` (docs/14 UX-08).
    ///
    /// Deliberately sparse. A symbol beside every row is wallpaper: the eye stops using
    /// them to find anything and the menu reads as a texture. These are the ones that
    /// distinguish a mode from its neighbours at a glance.
    var menuSymbol: String? {
        switch self {
        case .allInOne: "square.on.square.dashed"
        case .captureArea: "rectangle.dashed"
        case .captureWindow: "macwindow"
        case .captureFullscreen: "display"
        case .captureScrolling: "arrow.down.doc"
        case .captureText: "text.viewfinder"
        case .pickColor: "eyedropper"
        case .recordRegion: "rectangle.badge.record"
        case .recordDisplay: "record.circle"
        case .selfTimer: "timer"
        case .freezeScreen: "snowflake"
        default: nil
        }
    }

    /// How Settings ▸ Shortcuts groups every command (docs/03 §8.3).
    ///
    /// The one list of them. The menu-bar menu no longer lists capture commands — the
    /// island does — so these groups exist for the recorder pane, and a test holds them to
    /// covering every case exactly once: a command missing here is a command whose
    /// shortcut nobody can set, now that most of them ship without one.
    static var shortcutSections: [(title: String, commands: [CaptureCommand])] {
        [
            ("Capture", [
                .allInOne, .captureArea, .captureWindow, .captureFullscreen,
                .captureScrolling, .captureText, .pickColor, .capturePreviousArea,
                .captureAreaAndCopy, .captureAreaAndSave
            ]),
            ("Recording", [.recordSetup, .recordRegion, .recordDisplay, .stopRecording, .pauseRecording]),
            ("Utilities", [.selfTimer, .freezeScreen, .toggleDesktopIcons]),
            ("Overlays and Pins", [
                .saveAllOverlays, .closeAllOverlays, .hideOverlays, .pinClipboard, .hidePins,
                .togglePinClickThrough
            ]),
            ("Library", [.openHistory, .openSaveFolder])
        ]
    }
}
