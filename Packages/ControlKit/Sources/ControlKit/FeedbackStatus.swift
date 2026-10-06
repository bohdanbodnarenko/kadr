import Foundation
import SwiftUI

/// What kind of news a piece of feedback carries (docs/14 UX-24, docs/18 X-2).
///
/// Shared by the agent, the annotation editor and the studio, so the same failure reads
/// the same everywhere: one symbol and one tint per kind.
///
/// The rule for choosing a surface (docs/04 §5, "Feedback"):
/// - **Banner** for a recoverable failure or warning: non-modal, stays until dismissed,
///   carries the retry.
/// - **Alert** only to confirm something destructive before it happens.
/// - **Toast** (a completion banner) for a finished action whose result is not already on
///   screen; it takes itself away.
public enum FeedbackKind: Equatable, Sendable {
    case progress
    case completion
    case warning
    case error

    /// The SF Symbol every surface draws for this kind.
    public var symbolName: String {
        switch self {
        case .progress: "ellipsis.circle"
        case .completion: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    /// The tint every surface draws the symbol in.
    public var tint: Color {
        switch self {
        case .progress: .secondary
        case .completion: .green
        case .warning: .orange
        case .error: .red
        }
    }

    /// Whether the user has to dismiss it. Failures and warnings stay; completions go by
    /// themselves; progress is replaced by its outcome.
    public var staysUntilDismissed: Bool {
        self == .error || self == .warning
    }
}

/// One status for user-initiated work: what happened, and the way out (docs/14 UX-24).
///
/// A value type so each app renders it in its own chrome while the kind, symbol, tint and
/// dismissal rule stay common. See `FeedbackKind` for which surface to use.
public struct FeedbackStatus: Equatable, Identifiable {
    public let id: UUID
    public var kind: FeedbackKind
    public var message: String
    public var progress: Double?
    public var recoveryTitle: String?
    public var recovery: (() -> Void)?
    /// How long a completion stays up. Longer for one that carries an Undo, so there is
    /// time to reach it (docs/17 §5 theme 3).
    public var lingers: Duration = .seconds(3)

    /// When the banner should take itself away, or nil if it stays until dismissed.
    public var autoDismissDelay: Duration? {
        kind == .completion ? lingers : nil
    }

    public init(
        id: UUID = UUID(),
        kind: FeedbackKind,
        message: String,
        progress: Double? = nil,
        recoveryTitle: String? = nil,
        recovery: (() -> Void)? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.progress = progress
        self.recoveryTitle = recoveryTitle
        self.recovery = recovery
    }

    public static func == (lhs: FeedbackStatus, rhs: FeedbackStatus) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.message == rhs.message
            && lhs.progress == rhs.progress
            && lhs.recoveryTitle == rhs.recoveryTitle
            && lhs.lingers == rhs.lingers
    }
}

public extension FeedbackStatus {
    /// A finished action whose result is not otherwise on screen. Transient.
    static func done(_ message: String) -> FeedbackStatus {
        FeedbackStatus(kind: .completion, message: message)
    }

    /// A destructive action that already happened, with a way back (docs/17 §5 theme 3).
    ///
    /// The HIG prefers undo to a confirmation for frequent destructive actions: the action
    /// runs at once and this offers to reverse it for a few seconds.
    static func undoable(_ message: String, undo: @escaping () -> Void) -> FeedbackStatus {
        var status = FeedbackStatus(
            kind: .completion,
            message: message,
            recoveryTitle: String(localized: "Undo"),
            recovery: undo
        )
        status.lingers = undoWindow
        return status
    }

    /// How long an Undo stays on offer.
    static let undoWindow: Duration = .seconds(8)

    /// Something the user asked for went wrong, with a way to try again.
    static func failure(
        _ message: String,
        retryTitle: String? = nil,
        retry: (() -> Void)? = nil
    ) -> FeedbackStatus {
        FeedbackStatus(kind: .error, message: message, recoveryTitle: retryTitle, recovery: retry)
    }
}
