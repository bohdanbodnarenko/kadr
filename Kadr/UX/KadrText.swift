import Foundation

/// Localization and pseudolocalization for the agent (docs/14 UX-01).
///
/// Capture terms such as “pin”, “overlay”, “studio”, and “flatten” live in the string
/// catalog with translator comments. Launch with `-KadrPseudolocalize` to expand every
/// resolved string to roughly 1.4× so layout can be tested without a second locale.
enum KadrText {
    nonisolated static let pseudolocalizeArgument = "-KadrPseudolocalize"

    nonisolated static var isPseudolocalized: Bool {
        ProcessInfo.processInfo.arguments.contains(pseudolocalizeArgument)
    }

    nonisolated static func string(_ value: String.LocalizationValue) -> String {
        expand(String(localized: value))
    }

    nonisolated static func expand(_ value: String) -> String {
        guard isPseudolocalized else { return value }
        return Pseudolocalization.expand(value)
    }
}

enum Pseudolocalization {
    /// Roughly 1.4× expansion, wrapping every label that may wrap, without inventing
    /// extra words that would hide clipping of the real copy.
    nonisolated static func expand(_ value: String) -> String {
        let extra = max(Int((Double(value.count) * 0.4).rounded()), 1)
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
}
