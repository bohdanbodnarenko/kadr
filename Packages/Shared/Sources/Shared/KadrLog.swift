import os

/// Logging and signposting for the whole app (docs/04 §2, §7.6).
///
/// Every path with a PRD §8 budget gets a signpost interval, so the budgets can be
/// measured in Instruments and in CI rather than argued about. Signposts are never
/// removed once added (CLAUDE.md rule 8).
public enum KadrLog {
    /// One subsystem for every process in the app family, so an Instruments trace of
    /// the agent, the editor and the XPC helper reads as one story.
    public static let subsystem = "app.kadr.Kadr"

    /// Log categories, one per architectural area of docs/04 §1.
    public enum Category: String, CaseIterable, Sendable {
        case app
        case hotkeys
        case settings
        case overlay
        case capture
        case recording
        case history
    }

    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    public static func signposter(_ category: Category) -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: category.rawValue)
    }
}
