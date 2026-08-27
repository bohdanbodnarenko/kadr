import Foundation
import Shared

/// What a filename template can be filled in from.
public struct FilenameContext: Sendable, Hashable {
    /// The app that was frontmost when the capture was taken.
    public var applicationName: String?
    public var width: Int
    public var height: Int
    public var date: Date
    /// Bumped by the writer when a name is already taken.
    public var counter: Int

    public init(
        applicationName: String? = nil,
        width: Int = 0,
        height: Int = 0,
        date: Date = Date(),
        counter: Int = 1
    ) {
        self.applicationName = applicationName
        self.width = width
        self.height = height
        self.date = date
        self.counter = counter
    }
}

/// Expands filename templates like `{app}-{date}-{time}` (docs/03 §8.3).
///
/// A tiny, total function: unknown tokens are left as written rather than dropped, so a
/// typo shows up in the filename instead of silently vanishing, and every expansion is
/// sanitised because `/` and `:` in an app name would otherwise create directories or
/// break the file.
public struct FilenameTemplate: Sendable, Hashable {
    public static let `default` = FilenameTemplate("{app}-{date}-{time}")

    public let pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    /// Characters that cannot appear in a filename on macOS, plus a few that make
    /// filenames miserable to work with in a shell.
    private static let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>\u{0}")

    public func expand(_ context: FilenameContext) -> String {
        var result = ""
        var token = ""
        var inToken = false

        for character in pattern {
            switch character {
            case "{" where !inToken:
                inToken = true
                token = ""
            case "}" where inToken:
                inToken = false
                result += value(for: token, context: context) ?? "{\(token)}"
            case _ where inToken:
                token.append(character)
            default:
                result.append(character)
            }
        }
        // An unterminated token is written out as typed.
        if inToken {
            result += "{" + token
        }

        let sanitised = Self.sanitise(result)
        return sanitised.isEmpty ? Self.sanitise(Self.default.expand(context)) : sanitised
    }

    private func value(for token: String, context: FilenameContext) -> String? {
        switch token.lowercased() {
        case "app": Self.sanitise(context.applicationName ?? "Screen")
        case "date": Self.dateFormatter.string(from: context.date)
        case "time": Self.timeFormatter.string(from: context.date)
        case "w", "width": "\(context.width)"
        case "h", "height": "\(context.height)"
        case "wxh", "size": "\(context.width)x\(context.height)"
        case "counter": "\(context.counter)"
        default: nil
        }
    }

    /// Strips characters that are illegal or awkward in a filename, and trims the
    /// leading dot that would otherwise hide the file.
    static func sanitise(_ value: String) -> String {
        let cleaned = value
            .components(separatedBy: illegal)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.hasPrefix(".") ? String(cleaned.dropFirst()) : cleaned
    }

    /// Fixed formats, not localised: a filename with a locale-dependent date sorts
    /// differently on every machine and breaks scripts.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH.mm.ss"
        return formatter
    }()
}
