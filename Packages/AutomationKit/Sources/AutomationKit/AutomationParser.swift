import Foundation
import Shared

/// Turns a `kadr://` URL or an argument vector into an `AppCommand` (docs/03 §8.4).
///
/// One parser, two syntaxes: the URL scheme and the CLI accept the same verbs and the
/// same parameter names, so anything documented for one works in the other. Everything
/// here is pure — no file system, no agent, no AppKit — which is what makes the exhaustive
/// table-driven tests in `AutomationParserTests` possible (CLAUDE.md rule 9).
public enum AutomationParser {
    /// The scheme registered in the app's Info.plist.
    public static let scheme = "kadr"

    // MARK: - URL

    /// Parses `kadr://capture-area?action=copy&x=0&y=0&w=100&h=100`.
    ///
    /// The verb may be the host (`kadr://capture-area`) or the first path component
    /// (`kadr:capture-area`), because both spellings survive being pasted into different
    /// launchers and neither is worth losing a user over.
    public static func command(from url: URL) throws -> AppCommand {
        guard url.scheme?.lowercased() == scheme else {
            throw AutomationError.notAKadrURL(url.absoluteString)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rawVerb = components?.host.flatMap { $0.isEmpty ? nil : $0 }
            ?? url.pathComponents.first { $0 != "/" }
            ?? ""
        guard !rawVerb.isEmpty else { throw AutomationError.missingVerb }
        guard let verb = AutomationVerb.canonical(for: rawVerb) else {
            throw AutomationError.unknownVerb(rawVerb)
        }

        var values: [AutomationParameter: String] = [:]
        for item in components?.queryItems ?? [] {
            guard let parameter = AutomationParameter.named(item.name),
                  verb.parameters.contains(parameter)
            else {
                throw AutomationError.unknownParameter(verb: verb.rawValue, name: item.name)
            }
            // A flag with no value in a URL (`…?cursor`) reads as "on", which is what
            // someone writing it by hand means.
            values[parameter] = item.value ?? "true"
        }
        return try command(verb: verb, values: values)
    }

    // MARK: - Command line

    /// A parsed `kadr` invocation: what to do, and how the CLI should report it.
    public struct Invocation: Hashable, Sendable {
        public var command: AppCommand
        /// `--json`: machine-readable output on stdout.
        public var wantsJSON: Bool
        /// `--no-wait`: fire the command and exit 0 without waiting for the capture.
        public var waitsForResult: Bool
        /// `--timeout <seconds>`: how long to wait before giving up.
        public var timeout: TimeInterval

        public init(
            command: AppCommand,
            wantsJSON: Bool = false,
            waitsForResult: Bool = true,
            timeout: TimeInterval = Invocation.defaultTimeout
        ) {
            self.command = command
            self.wantsJSON = wantsJSON
            self.waitsForResult = waitsForResult
            self.timeout = timeout
        }

        /// Long enough for a user to frame a selection and let go, short enough that a
        /// script that forgot the agent is gone does not hang a CI job forever.
        public static let defaultTimeout: TimeInterval = 120

        /// For commands that only open a window or flip a switch. They answer at once, so
        /// waiting two minutes for one would only ever mean the agent is wedged.
        public static let quickTimeout: TimeInterval = 10
    }

    /// Parses `capture-area --action copy --x 0 --y 0 --w 100 --h 100 --json`.
    ///
    /// - Parameter arguments: the argument vector *without* the executable name.
    ///
    /// Both `--name value` and `--name=value` are accepted, and a boolean parameter may
    /// be written as a bare flag (`--cursor`) or negated (`--no-cursor`).
    public static func invocation(arguments: [String]) throws -> Invocation {
        var arguments = arguments
        guard let rawVerb = arguments.first, !rawVerb.hasPrefix("-") else {
            throw AutomationError.missingVerb
        }
        arguments.removeFirst()
        guard let verb = AutomationVerb.canonical(for: rawVerb) else {
            throw AutomationError.unknownVerb(rawVerb)
        }

        var scanner = ArgumentScanner()
        var index = 0
        while index < arguments.count {
            try scanner.consume(from: arguments, at: &index, verb: verb)
        }

        let command = try command(verb: verb, values: scanner.values)
        return Invocation(
            command: command,
            wantsJSON: scanner.wantsJSON,
            waitsForResult: scanner.waits,
            // A capture waits on the user; opening Settings does not.
            timeout: scanner.explicitTimeout
                ?? (command.producesOutput ? Invocation.defaultTimeout : Invocation.quickTimeout)
        )
    }

    /// Reads the flags off a command line, one token at a time.
    private struct ArgumentScanner {
        var values: [AutomationParameter: String] = [:]
        var wantsJSON = false
        var waits = true
        var explicitTimeout: TimeInterval?

        mutating func consume(from arguments: [String], at index: inout Int, verb: AutomationVerb) throws {
            let token = arguments[index]
            index += 1
            guard token.hasPrefix("--") else {
                throw AutomationError.unknownParameter(verb: verb.rawValue, name: token)
            }

            var name = String(token.dropFirst(2))
            var inline: String?
            if let equals = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }

            if try consumeGlobalFlag(named: name, inline: inline, from: arguments, at: &index) {
                return
            }
            try consumeParameter(named: name, inline: inline, from: arguments, at: &index, verb: verb)
        }

        /// The flags that belong to the CLI rather than to a verb. Returns whether the
        /// token was one of them.
        private mutating func consumeGlobalFlag(
            named name: String,
            inline: String?,
            from arguments: [String],
            at index: inout Int
        ) throws -> Bool {
            switch name {
            case "json":
                wantsJSON = true
            case "wait":
                waits = true
            case "no-wait":
                waits = false
            case "timeout":
                let raw = try inline ?? next(&index, in: arguments, for: "timeout")
                guard let seconds = TimeInterval(raw), seconds > 0 else {
                    throw AutomationError.invalidValue(name: "timeout", value: raw)
                }
                explicitTimeout = seconds
            default:
                return false
            }
            return true
        }

        private mutating func consumeParameter(
            named name: String,
            inline: String?,
            from arguments: [String],
            at index: inout Int,
            verb: AutomationVerb
        ) throws {
            // `--no-cursor` turns a boolean parameter off.
            let negated = negatedBoolean(in: name)

            guard let parameter = AutomationParameter.named(negated ?? name),
                  verb.parameters.contains(parameter)
            else {
                throw AutomationError.unknownParameter(verb: verb.rawValue, name: name)
            }

            if negated != nil {
                values[parameter] = "false"
            } else if let inline {
                values[parameter] = inline
            } else if isBoolean(parameter), index >= arguments.count || arguments[index].hasPrefix("--") {
                values[parameter] = "true"
            } else {
                values[parameter] = try next(&index, in: arguments, for: name)
            }
        }

        /// The parameter `--no-…` refers to, when it names a boolean one.
        private func negatedBoolean(in name: String) -> String? {
            guard name.hasPrefix("no-") else { return nil }
            guard let parameter = AutomationParameter.named(String(name.dropFirst(3))),
                  isBoolean(parameter)
            else {
                return nil
            }
            return parameter.rawValue
        }

        private func next(_ index: inout Int, in arguments: [String], for name: String) throws -> String {
            guard index < arguments.count else { throw AutomationError.missingValue(name: name) }
            defer { index += 1 }
            return arguments[index]
        }

        private func isBoolean(_ parameter: AutomationParameter) -> Bool {
            switch parameter {
            case .cursor, .microphone, .systemAudio: true
            default: false
            }
        }
    }

    // MARK: - Shared assembly

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
        case .stopRecording: .stopRecording
        default: nil
        }
    }

    private static func fileCommand(
        verb: AutomationVerb,
        values: [AutomationParameter: String]
    ) throws -> AppCommand? {
        switch verb {
        case .pin: try .pin(FileTarget(path: requiredPath(values, verb: verb)))
        case .annotate: try .annotate(FileTarget(path: requiredPath(values, verb: verb)))
        case .addToHistory: try .addToHistory(FileTarget(path: requiredPath(values, verb: verb)))
        case .closeAllPins: .closeAllPins
        case .restoreRecentlyClosed: .restoreRecentlyClosed
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
            try .openSettings(enumeration(values[.tab], name: .tab))
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

    // MARK: - Values

    private static func captureOptions(_ values: [AutomationParameter: String]) throws -> CaptureOptions {
        var options = CaptureOptions()
        options.action = try enumeration(values[.action], name: .action)
        options.region = try region(values)
        options.delay = try nonNegativeInteger(values[.delay], name: .delay)
        options.includesCursor = try boolean(values[.cursor], name: .cursor)
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

    private static func boolean(_ raw: String?, name: AutomationParameter) throws -> Bool? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: throw AutomationError.invalidValue(name: name.rawValue, value: raw)
        }
    }
}
