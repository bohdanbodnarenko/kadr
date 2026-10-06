import Foundation

/// Localization for the agent, and how to see the app in a pseudolanguage (docs/14 UX-01,
/// docs/18 X-4).
///
/// Kadr has no pseudolocalization of its own. It used to wrap the strings that went through
/// this type in "⟦…⟧", which reached about 8% of the UI. The system's pseudolanguage reaches
/// every string that comes out of a bundle, SwiftUI's and AppKit's included:
///
/// - `make run-pseudo` launches with `-NSDoubleLocalizedStrings YES`, which doubles every
///   localized string ("Cancel Cancel"), the stress case for layout.
/// - `make run-rtl` launches with `-AppleTextDirection YES -NSForceRightToLeftWritingDirection
///   YES`, which lays the app out right to left in English.
enum KadrText {
    /// The Foundation default behind the double-length pseudolanguage.
    nonisolated static let doubleLengthDefault = "NSDoubleLocalizedStrings"
    /// The Foundation default that forces right-to-left writing direction.
    nonisolated static let rightToLeftDefault = "NSForceRightToLeftWritingDirection"

    nonisolated static var isPseudolocalized: Bool {
        UserDefaults.standard.bool(forKey: doubleLengthDefault)
    }

    nonisolated static var isRightToLeft: Bool {
        UserDefaults.standard.bool(forKey: rightToLeftDefault)
    }

    nonisolated static func string(_ value: String.LocalizationValue) -> String {
        String(localized: value)
    }

    /// A string with a count in it, agreeing in number through automatic grammar agreement:
    /// `"^[\(n) word](inflect: true)"` reads "1 word" and "3 words", and a translation can
    /// agree the way its own language does. Splicing an "s" on in code can do neither
    /// (docs/18 X-4).
    nonisolated static func counted(_ value: String.LocalizationValue) -> String {
        String(AttributedString(localized: value).characters)
    }
}

enum Pseudolocalization {
    /// What the double-length pseudolanguage renders a string as: the string, a space, and
    /// the string again. Layout tests measure against this rather than toggling the default,
    /// which Foundation reads once per process.
    nonisolated static func doubled(_ value: String) -> String {
        "\(value) \(value)"
    }
}

/// Pluralization for counts that used to be `"word\(count == 1 ? "" : "s")"`.
enum KadrPlural {
    nonisolated static func captures(_ count: Int) -> String {
        KadrText.string("\(count) captures")
    }

    nonisolated static func files(_ count: Int) -> String {
        KadrText.string("\(count) files")
    }

    nonisolated static func words(_ count: Int) -> String {
        KadrText.string("\(count) words")
    }

    nonisolated static func seconds(_ count: Int) -> String {
        KadrText.string("\(count) seconds")
    }

    nonisolated static func cards(_ count: Int) -> String {
        KadrText.string("\(count) cards")
    }

    nonisolated static func codes(_ count: Int) -> String {
        KadrText.string("\(count) codes")
    }

    nonisolated static func lines(_ count: Int) -> String {
        KadrText.string("\(count) lines")
    }
}
