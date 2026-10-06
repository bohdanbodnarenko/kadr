import Foundation

/// Localization and pseudolocalization for the agent (docs/14 UX-01).
///
/// Capture terms such as “pin”, “overlay”, “studio”, and “flatten” live in the string
/// catalog with translator comments. Launch with `-KadrPseudolocalize` to expand every
/// resolved string to roughly 1.4× so layout can be tested without a second locale.
enum KadrText {
    nonisolated static let pseudolocalizeArgument = "-KadrPseudolocalize"
    nonisolated static let pseudolocalize2xArgument = "-KadrPseudolocalize2x"
    nonisolated static let rtlArgument = "-KadrRTL"

    nonisolated static var isPseudolocalized: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(pseudolocalizeArgument) || arguments.contains(pseudolocalize2xArgument)
    }

    nonisolated static var isRightToLeft: Bool {
        ProcessInfo.processInfo.arguments.contains(rtlArgument)
    }

    nonisolated static var expansionFactor: Double {
        if ProcessInfo.processInfo.arguments.contains(pseudolocalize2xArgument) {
            return 2.0
        }
        return isPseudolocalized ? 1.4 : 1.0
    }

    nonisolated static func string(_ value: String.LocalizationValue) -> String {
        expand(String(localized: value))
    }

    /// A string with a count in it, agreeing in number through automatic grammar agreement:
    /// `"^[\(n) word](inflect: true)"` reads "1 word" and "3 words", and a translation can
    /// agree the way its own language does. Splicing an "s" on in code can do neither
    /// (docs/18 X-4).
    nonisolated static func counted(_ value: String.LocalizationValue) -> String {
        expand(String(AttributedString(localized: value).characters))
    }

    nonisolated static func expand(_ value: String) -> String {
        guard isPseudolocalized else { return value }
        return Pseudolocalization.expand(value, factor: expansionFactor)
    }
}

enum Pseudolocalization {
    /// Expansion that wraps every label that may wrap, without inventing extra words
    /// that would hide clipping of the real copy. 1.4× is the layout default; 2× is
    /// the stress case in docs/14 §6.
    nonisolated static func expand(_ value: String, factor: Double = 1.4) -> String {
        let extra = max(Int((Double(value.count) * max(factor - 1, 0)).rounded()), 1)
        let pad = String(repeating: "·", count: extra)
        return "⟦\(value) \(pad)⟧"
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
