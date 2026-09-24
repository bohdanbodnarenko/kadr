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

        let sanitised = Self.truncated(Self.sanitise(result))
        return sanitised.isEmpty ? Self.truncated(Self.sanitise(Self.default.expand(context))) : sanitised
    }

    /// The most UTF-8 bytes an expanded name may use (docs/17 T-OUT-6).
    ///
    /// APFS allows 255 bytes per name. The rest is headroom for a " (32)" collision
    /// suffix and an extension, so a long window title never makes the write fail.
    public static let maxNameBytes = 200

    /// Cuts `name` to `maxBytes` of UTF-8 on a character boundary, so an emoji or an
    /// accented letter is never split into invalid bytes.
    public static func truncated(_ name: String, maxBytes: Int = maxNameBytes) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var result = ""
        var used = 0
        for character in name {
            let size = character.utf8.count
            guard used + size <= maxBytes else { break }
            result.append(character)
            used += size
        }
        return result.trimmingCharacters(in: .whitespaces)
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
    public static func sanitise(_ value: String) -> String {
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
