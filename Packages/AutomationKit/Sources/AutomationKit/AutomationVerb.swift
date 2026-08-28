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
    case recordScreen = "record-screen"
    case recordRegion = "record-region"
    case stopRecording = "stop-recording"
    case pin
    case annotate
    case addToHistory = "add-to-history"
    case closeAllPins = "close-all-pins"
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
        case .recordScreen: "Start recording a display."
        case .recordRegion: "Select a region and start recording it."
        case .stopRecording: "Stop the recording in progress."
        case .pin: "Pin an image file on top of every window."
        case .annotate: "Open an image file in the editor."
        case .addToHistory: "Add a file to Kadr's capture library."
        case .closeAllPins: "Close every pinned screenshot."
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
        case .captureArea, .captureWindow, .captureFullscreen, .capturePreviousArea, .captureScrolling:
            [.action, .x, .y, .width, .height, .delay, .cursor]
        case .captureText:
            [.x, .y, .width, .height, .delay]
        case .pickColor:
            []
        case .recordScreen, .recordRegion:
            [.fps, .x, .y, .width, .height, .microphone, .systemAudio]
        case .pin, .annotate, .addToHistory:
            [.path]
        case .toggleDesktopIcons:
            [.state]
        case .openSettings:
            [.tab]
        case .stopRecording, .closeAllPins, .restoreRecentlyClosed, .freezeScreen, .openHistory, .version:
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
        // The annotate window.
        "open-annotate": .annotate,
        "annotate-file": .annotate,
        // Timed and all-in-one captures both begin as an area selection here; the delay
        // comes from Settings unless the caller passes one.
        "self-timer": .captureArea,
        "all-in-one": .captureArea,
        // Kadr records video and exports GIF from the overlay card, so the GIF verb
        // starts the same recording.
        "record-gif": .recordScreen,
        "stop-capture": .stopRecording,
        "toggle-desktop": .toggleDesktopIcons,
        "hide-desktop-icons": .toggleDesktopIcons,
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
