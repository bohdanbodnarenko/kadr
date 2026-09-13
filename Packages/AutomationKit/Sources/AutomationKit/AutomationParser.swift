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
        if let desktop = Self.desktopIconsCommand(for: rawVerb) {
            return desktop
        }
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
        guard let verb = AutomationVerb.canonical(for: rawVerb) ?? desktopIconsVerb(for: rawVerb) else {
            throw AutomationError.unknownVerb(rawVerb)
        }

        var scanner = ArgumentScanner()
        var index = 0
        while index < arguments.count {
            try scanner.consume(from: arguments, at: &index, verb: verb)
        }

        let parsed = if let desktop = desktopIconsCommand(for: rawVerb) {
            desktop
        } else {
            try command(verb: verb, values: scanner.values)
        }
        return Invocation(
            command: parsed,
            wantsJSON: scanner.wantsJSON,
            waitsForResult: scanner.waits,
            // A capture waits on the user; opening Settings does not.
            timeout: scanner.explicitTimeout
                ?? (parsed.producesOutput ? Invocation.defaultTimeout : Invocation.quickTimeout)
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
            case .cursor, .microphone, .systemAudio, .linebreaks: true
            default: false
            }
        }
    }
}
