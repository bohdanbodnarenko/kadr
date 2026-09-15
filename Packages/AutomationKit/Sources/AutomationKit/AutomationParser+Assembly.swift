import Foundation
import Shared

/// Verb assembly, split from the parser because the enum body was already at its
/// length budget before All-in-One and overlay verbs landed.
extension AutomationParser {
    /// Builds the command once the syntax is out of the way.
    ///
    /// Split by family rather than written as one switch: nineteen verbs in a single
    /// function is a shape that gets harder to read with every verb added.
    public static func command(
        verb: AutomationVerb,
        values: [AutomationParameter: String]
    ) throws -> AppCommand {
        if let capture = try captureCommand(verb: verb, values: values) {
            return capture
        }
        if let recording = try recordingCommand(verb: verb, values: values) {
            return recording
        }
        if let file = try fileCommand(verb: verb, values: values) {
            return file
        }
        return try chromeCommand(verb: verb, values: values)
    }

    /// `hide-desktop-icons` / `show-desktop-icons` are CleanShot spellings that name a
    /// state rather than a toggle. They are not canonical verbs (that would shadow
    /// `toggle-desktop-icons`) and not aliases (an alias cannot carry `state=`).
    static func desktopIconsCommand(for raw: String) -> AppCommand? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "hide-desktop-icons": .toggleDesktopIcons(.on)
        case "show-desktop-icons": .toggleDesktopIcons(.off)
        default: nil
        }
    }

    static func desktopIconsVerb(for raw: String) -> AutomationVerb? {
        desktopIconsCommand(for: raw) == nil ? nil : .toggleDesktopIcons
    }

    private static func captureCommand(
        verb: AutomationVerb,
        values: [AutomationParameter: String]
    ) throws -> AppCommand? {
        switch verb {
        case .captureArea: try .captureArea(captureOptions(values))
        case .captureWindow: try .captureWindow(captureOptions(values))
        case .captureFullscreen: try .captureFullscreen(captureOptions(values))
        case .capturePreviousArea: try .capturePreviousArea(captureOptions(values))
        case .captureText: try .captureText(captureOptions(values))
        case .captureScrolling: try .captureScrolling(captureOptions(values))
        case .allInOne: try .allInOne(captureOptions(values))
        case .selfTimer: try .selfTimer(captureOptions(values))
        case .pickColor: .pickColor
        default: nil
        }
    }

    private static func recordingCommand(
        verb: AutomationVerb,
        values: [AutomationParameter: String]
    ) throws -> AppCommand? {
        switch verb {
        case .recordScreen: try .recordScreen(recordOptions(values))
        case .recordRegion: try .recordRegion(recordOptions(values))
        case .recordGif: try .recordRegion(gifOptions(values))
        case .stopRecording: .stopRecording
        case .toggleRecording: .toggleRecording
        default: nil
        }
    }

    private static func fileCommand(
        verb: AutomationVerb,
        values: [AutomationParameter: String]
    ) throws -> AppCommand? {
        if let overlay = overlayFileCommand(verb) {
            return overlay
        }
        return switch verb {
        case .pin: .pin(optionalPath(values))
        case .annotate: try .annotate(FileTarget(path: requiredPath(values, verb: verb)))
        case .addToHistory: try .addToHistory(FileTarget(path: requiredPath(values, verb: verb)))
        case .addQuickAccessOverlay: try .addQuickAccessOverlay(FileTarget(path: requiredPath(values, verb: verb)))
        case .openFromClipboard: .openFromClipboard
        case .closeAllPins: .closeAllPins
        case .hidePins: .hidePins
        case .restoreRecentlyClosed: .restoreRecentlyClosed
        default: nil
        }
    }

    /// Overlay-stack verbs that do not take a path.
    private static func overlayFileCommand(_ verb: AutomationVerb) -> AppCommand? {
        switch verb {
        case .closeAllOverlays: .closeAllOverlays
        case .saveAllOverlays: .saveAllOverlays
        case .hideOverlays: .hideOverlays
        default: nil
        }
    }

    private static func chromeCommand(
        verb: AutomationVerb,
        values: [AutomationParameter: String]
    ) throws -> AppCommand {
        switch verb {
        case .toggleDesktopIcons:
            try .toggleDesktopIcons(enumeration(values[.state], name: .state) ?? .toggle)
        case .openSettings:
            try .openSettings(settingsTab(values[.tab]))
        case .freezeScreen:
            .freezeScreen
        case .openHistory:
            .openHistory
        default:
            // Every other verb belongs to one of the families above. A new verb that
            // forgets to be routed lands here rather than being silently mis-parsed —
            // and `AutomationParserTests` walks every case, so it would not get far.
            .version
        }
    }

    private static func captureOptions(_ values: [AutomationParameter: String]) throws -> CaptureOptions {
        var options = CaptureOptions()
        options.action = try enumeration(values[.action], name: .action)
        options.region = try region(values)
        options.delay = try nonNegativeInteger(values[.delay], name: .delay)
        options.includesCursor = try boolean(values[.cursor], name: .cursor)
        options.preservesLineBreaks = try boolean(values[.linebreaks], name: .linebreaks)
        options.display = try positiveInteger(values[.display], name: .display)
        options.path = optionalPath(values)?.path
        options.autoScroll = try boolean(values[.autoScroll], name: .autoScroll)
        options.startsImmediately = try boolean(values[.start], name: .start)
        return options
    }

    private static func recordOptions(_ values: [AutomationParameter: String]) throws -> RecordOptions {
        var options = RecordOptions()
        if let raw = values[.fps] {
            guard let fps = Int(raw), (1 ... 120).contains(fps) else {
                throw AutomationError.invalidValue(name: AutomationParameter.fps.rawValue, value: raw)
            }
            options.frameRate = fps
        }
        options.region = try region(values)
        options.recordsMicrophone = try boolean(values[.microphone], name: .microphone)
        options.recordsSystemAudio = try boolean(values[.systemAudio], name: .systemAudio)
        options.display = try positiveInteger(values[.display], name: .display)
        return options
    }

    private static func gifOptions(_ values: [AutomationParameter: String]) throws -> RecordOptions {
        var options = try recordOptions(values)
        options.exportAsGIF = true
        return options
    }

    /// All four or none: a region with a missing side is a bug in the caller, and
    /// defaulting it would capture the wrong pixels without saying so.
    private static func region(_ values: [AutomationParameter: String]) throws -> ScreenRect? {
        let sides: [AutomationParameter] = [.x, .y, .width, .height]
        let present = sides.filter { values[$0] != nil }
        guard !present.isEmpty else { return nil }
        guard present.count == sides.count else { throw AutomationError.incompleteRegion }

        var numbers: [AutomationParameter: CGFloat] = [:]
        for side in sides {
            guard let raw = values[side], let value = Double(raw) else {
                throw AutomationError.invalidValue(name: side.rawValue, value: values[side] ?? "")
            }
            numbers[side] = CGFloat(value)
        }
        let rect = ScreenRect(
            x: numbers[.x] ?? 0,
            y: numbers[.y] ?? 0,
            width: numbers[.width] ?? 0,
            height: numbers[.height] ?? 0
        )
        guard !rect.isEmpty else {
            throw AutomationError.invalidValue(
                name: AutomationParameter.width.rawValue,
                value: "\(rect.width)×\(rect.height)"
            )
        }
        return rect
    }

    private static func optionalPath(_ values: [AutomationParameter: String]) -> FileTarget? {
        guard let path = values[.path], !path.isEmpty else { return nil }
        return FileTarget(path: path)
    }

    private static func settingsTab(_ raw: String?) throws -> SettingsTab? {
        guard let raw else { return nil }
        guard let tab = SettingsTab.named(raw) else {
            throw AutomationError.invalidValue(name: AutomationParameter.tab.rawValue, value: raw)
        }
        return tab
    }

    private static func requiredPath(
        _ values: [AutomationParameter: String],
        verb: AutomationVerb
    ) throws -> String {
        guard let path = values[.path], !path.isEmpty else {
            throw AutomationError.missingRequiredParameter(
                verb: verb.rawValue,
                name: AutomationParameter.path.rawValue
            )
        }
        return path
    }

    /// A string-backed enum value, or an error naming what was wrong with it.
    private static func enumeration<Value: RawRepresentable>(
        _ raw: String?,
        name: AutomationParameter
    ) throws -> Value? where Value.RawValue == String {
        guard let raw else { return nil }
        guard let value = Value(rawValue: raw.lowercased()) else {
            throw AutomationError.invalidValue(name: name.rawValue, value: raw)
        }
        return value
    }

    private static func nonNegativeInteger(_ raw: String?, name: AutomationParameter) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw), value >= 0 else {
            throw AutomationError.invalidValue(name: name.rawValue, value: raw)
        }
        return value
    }

    /// Display indexes are 1-based (CleanShot §20: `display=1` is the primary).
    private static func positiveInteger(_ raw: String?, name: AutomationParameter) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw), value >= 1 else {
            throw AutomationError.invalidValue(name: name.rawValue, value: raw)
        }
        return value
    }

    private static func boolean(_ raw: String?, name: AutomationParameter) throws -> Bool? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: throw AutomationError.invalidValue(name: name.rawValue, value: raw)
        }
    }
}
