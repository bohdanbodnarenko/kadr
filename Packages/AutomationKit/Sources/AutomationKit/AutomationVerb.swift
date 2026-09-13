import Foundation

/// The verb vocabulary shared by the URL scheme, the CLI and Shortcuts (docs/03 §8.4).
///
/// Kebab-case because that is what a URL and a shell both read well, and because the
/// CleanShot verbs a migrating user already has in their Raycast scripts are spelled that
/// way — see `AutomationVerb.canonical(for:)` for the alias table that accepts them.
public enum AutomationVerb: String, CaseIterable, Sendable, Hashable {
    case captureArea = "capture-area"
    case captureWindow = "capture-window"
    case captureFullscreen = "capture-fullscreen"
    case capturePreviousArea = "capture-previous-area"
    case captureText = "capture-text"
    case pickColor = "pick-color"
    case captureScrolling = "capture-scrolling"
    case allInOne = "all-in-one"
    case selfTimer = "self-timer"
    case recordScreen = "record-screen"
    case recordRegion = "record-region"
    case recordGif = "record-gif"
    case stopRecording = "stop-recording"
    case pin
    case annotate
    case addToHistory = "add-to-history"
    case addQuickAccessOverlay = "add-quick-access-overlay"
    case openFromClipboard = "open-from-clipboard"
    case closeAllPins = "close-all-pins"
    case closeAllOverlays = "close-all-overlays"
    case saveAllOverlays = "save-all-overlays"
    case hideOverlays = "hide-overlays"
    case hidePins = "hide-pins"
    case restoreRecentlyClosed = "restore-recently-closed"
    case toggleDesktopIcons = "toggle-desktop-icons"
    case freezeScreen = "freeze-screen"
    case openHistory = "open-history"
    case openSettings = "open-settings"
    case version

    /// One line of help, used by `kadr help` and by docs/AUTOMATION.md's generator test.
    public var summary: String {
        switch self {
        case .captureArea: "Select an area and capture it."
        case .captureWindow: "Pick a window and capture it."
        case .captureFullscreen: "Capture every display."
        case .capturePreviousArea: "Re-capture the last area, without the overlay."
        case .captureText: "Select an area and recognise the text in it."
        case .pickColor: "Open the loupe as a colour picker."
        case .captureScrolling: "Capture a scrolling region and stitch it."
        case .allInOne: "Open the All-in-One capture HUD."
        case .selfTimer: "Count down, then capture an area."
        case .recordScreen: "Start recording a display."
        case .recordRegion: "Select a region and start recording it."
        case .recordGif: "Record a region, then export it as a GIF."
        case .stopRecording: "Stop the recording in progress."
        case .pin: "Pin an image file on top of every window."
        case .annotate: "Open an image file in the editor."
        case .addToHistory: "Add a file to Kadr's capture library."
        case .addQuickAccessOverlay: "Show a file as a Quick Access card."
        case .openFromClipboard: "Open the clipboard image or movie as a Quick Access card."
        case .closeAllPins: "Close every pinned screenshot."
        case .closeAllOverlays: "Dismiss every Quick Access card."
        case .saveAllOverlays: "Save every Quick Access card."
        case .hideOverlays: "Hide overlay cards so they miss the next capture."
        case .hidePins: "Hide or show every pinned screenshot."
        case .restoreRecentlyClosed: "Bring back the last dismissed overlay card."
        case .toggleDesktopIcons: "Hide or show the desktop icons."
        case .freezeScreen: "Freeze the displays so moving UI can be inspected."
        case .openHistory: "Open the history window."
        case .openSettings: "Open Settings, optionally on a named tab."
        case .version: "Print the running agent's version."
        }
    }

    /// The parameters this verb accepts. Anything else is a parse error rather than a
    /// silently ignored typo — a script that misspells `action` should be told so.
    public var parameters: [AutomationParameter] {
        switch self {
        case .captureArea, .captureWindow, .captureFullscreen, .capturePreviousArea,
             .allInOne, .selfTimer:
            [.action, .x, .y, .width, .height, .delay, .cursor, .display]
        case .captureScrolling:
            [.action, .x, .y, .width, .height, .delay, .cursor, .display, .start, .autoScroll]
        case .captureText:
            [.x, .y, .width, .height, .delay, .linebreaks, .display, .path]
        case .pickColor:
            []
        case .recordScreen, .recordRegion, .recordGif:
            [.fps, .x, .y, .width, .height, .microphone, .systemAudio, .display]
        case .pin, .annotate, .addToHistory, .addQuickAccessOverlay:
            [.path]
        case .toggleDesktopIcons:
            [.state]
        case .openSettings:
            [.tab]
        case .stopRecording, .closeAllPins, .closeAllOverlays, .saveAllOverlays, .hideOverlays,
             .hidePins, .restoreRecentlyClosed, .freezeScreen, .openHistory, .openFromClipboard,
             .version:
            []
        }
    }

    /// Accepts a canonical verb or one of the aliases, and normalises the case.
    ///
    /// The alias table exists so a Raycast or shell script written against CleanShot's
    /// URL scheme keeps working after `cleanshot://` is replaced with `kadr://`
    /// (docs/06 M19). Aliases only ever map onto a verb that does the same thing; the
    /// CleanShot verbs Kadr has no equivalent for are listed in docs/AUTOMATION.md as
    /// unsupported rather than being quietly pointed at something else.
    public static func canonical(for raw: String) -> AutomationVerb? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let verb = AutomationVerb(rawValue: key) {
            return verb
        }
        return aliases[key]
    }

    /// Alias → canonical. Left column is the spelling a script may already use.
    public static let aliases: [String: AutomationVerb] = [
        // CleanShot spells the scrolling verb the other way round.
        "scrolling-capture": .captureScrolling,
        "capture-scrolling-area": .captureScrolling,
        // Its fullscreen verb has two names, and "screen" reads more naturally in a shell.
        "capture-screen": .captureFullscreen,
        "capture-display": .captureFullscreen,
        "capture-fullscreen-all": .captureFullscreen,
        // OCR.
        "ocr": .captureText,
        "capture-ocr": .captureText,
        // Kadr spells the eyedropper as a colour verb; "pick-colour" is the same thing.
        "pick-colour": .pickColor,
        "color-picker": .pickColor,
        // The previous-area verb.
        "capture-previous": .capturePreviousArea,
        "capture-area-previous": .capturePreviousArea,
        // Pins are "floating screenshots" in CleanShot.
        "add-floating-screenshot": .pin,
        "float": .pin,
        "close-all-floating-screenshots": .closeAllPins,
        "close-floating-screenshots": .closeAllPins,
        "hide-floating-screenshots": .hidePins,
        "toggle-floating-screenshots": .hidePins,
        // The annotate window.
        "open-annotate": .annotate,
        "annotate-file": .annotate,
        // Overlay cards.
        "add-overlay": .addQuickAccessOverlay,
        "open-from-pasteboard": .openFromClipboard,
        "save-all": .saveAllOverlays,
        "hide-quick-access-overlay": .hideOverlays,
        "stop-capture": .stopRecording,
        "toggle-desktop": .toggleDesktopIcons,
        "open-preferences": .openSettings,
        "restore-recently-closed-window": .restoreRecentlyClosed
    ]
}

/// A parameter name, with the spellings the parser accepts for it.
public enum AutomationParameter: String, CaseIterable, Sendable, Hashable {
    case action
    case x
    case y
    case width
    case height
    case delay
    case cursor
    case fps
    case microphone
    case systemAudio = "system-audio"
    case path
    case state
    case tab
    case linebreaks
    case display
    case start
    case autoScroll = "autoscroll"

    /// Alternative spellings, kept small and obvious. `w`/`h` because the doc's own URL
    /// examples use them, `filepath` because that is CleanShot's name for it.
    public var aliases: [String] {
        switch self {
        case .width: ["w"]
        case .height: ["h"]
        case .path: ["filepath", "file"]
        case .fps: ["framerate", "frame-rate"]
        case .delay: ["timer", "seconds"]
        case .systemAudio: ["audio"]
        case .linebreaks: ["line-breaks"]
        default: []
        }
    }

    public static func named(_ raw: String) -> AutomationParameter? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let parameter = AutomationParameter(rawValue: key) {
            return parameter
        }
        return allCases.first { $0.aliases.contains(key) }
    }
}
