import AppKit
import ControlKit
import SwiftUI

/// The model itself lives in ControlKit, shared with the editor and the studio
/// (docs/18 X-2). The agent keeps what only it uses: the unavailable reasons, the
/// announcement, and its own chrome.
extension FeedbackStatus {
    /// An action that could not run. Stays until dismissed, and says why rather than
    /// leaving a disabled button and a tooltip behind (docs/14 UX-24B).
    static func unavailable(
        _ reason: ActionUnavailableReason,
        recoveryTitle: String? = nil,
        recovery: (() -> Void)? = nil
    ) -> FeedbackStatus {
        FeedbackStatus(
            kind: reason == .cancelled ? .completion : .warning,
            message: reason.message,
            recoveryTitle: recoveryTitle,
            recovery: recovery
        )
    }
}

/// Speaks a status change that has no focusable control of its own (docs/14 UX-24C).
///
/// A banner that appears somewhere on screen is invisible to VoiceOver until something
/// moves the cursor into it, so the important ones are announced as well as drawn.
@MainActor
enum FeedbackAnnouncement {
    static func post(_ message: String, priority: NSAccessibilityPriorityLevel = .high) {
        guard let element = NSApp.mainWindow ?? NSApp.windows.first else { return }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }
}

/// Why a card action cannot run. Distinct from “coming soon” (docs/14 UX-24B).
enum ActionUnavailableReason: Equatable, Sendable {
    case editorNotInstalled
    case couldNotReadText
    case missingFile
    case diskFull
    case permissionDenied(String)
    case cancelled
    case other(String)

    var message: String {
        switch self {
        case .editorNotInstalled:
            String(localized: "Editor is not installed")
        case .couldNotReadText:
            String(localized: "Could not read text")
        case .missingFile:
            String(localized: "The file is no longer on disk")
        case .diskFull:
            String(localized: "Not enough disk space")
        case let .permissionDenied(name):
            String(localized: "\(name) permission is required")
        case .cancelled:
            String(localized: "Cancelled")
        case let .other(message):
            message
        }
    }
}

/// Status drawn directly under a control (docs/14 UX-13).
///
/// Success is transient; failures stay until dismissed or corrected. Adjacent to the
/// control that changed, not as secondary copy several rows below it.
struct ControlInlineStatus: View {
    let status: FeedbackStatus?
    var onDismiss: () -> Void = {}

    var body: some View {
        if let status {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol(for: status.kind))
                    .foregroundStyle(tint(for: status.kind))
                    .font(.caption)
                    .accessibilityHidden(true)
                Text(status.message)
                    .font(.callout)
                    .foregroundStyle(status.kind == .error ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = status.recoveryTitle {
                    Button(title) { status.recovery?() }
                        .controlSize(.small)
                }
                if status.kind.staysUntilDismissed {
                    Button("Dismiss", action: onDismiss)
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.message)
            .task(id: status.id) {
                guard status.kind == .completion else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled {
                    onDismiss()
                }
            }
        }
    }

    private func symbol(for kind: FeedbackKind) -> String {
        kind.symbolName
    }

    private func tint(for kind: FeedbackKind) -> Color {
        kind.tint
    }
}

/// Anchored, non-blocking banner. Auto-dismiss pauses while the pointer or VoiceOver
/// focus is inside it.
struct FeedbackBanner: View {
    let status: FeedbackStatus
    var onDismiss: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.message)
                    .font(.callout)
                if let progress = status.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 180)
                }
            }
            Spacer(minLength: 8)
            if let title = status.recoveryTitle {
                Button(title) { status.recovery?() }
                    .controlSize(.small)
            }
            if status.kind != .progress {
                Button("Dismiss", action: onDismiss)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .kadrChrome(cornerRadius: 8)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(status.kind == .error ? .isStaticText : [])
        .accessibilityLabel(status.message)
        .task(id: status.id) {
            guard let delay = status.autoDismissDelay else { return }
            try? await Task.sleep(for: delay)
            // Never take a banner out from under the pointer: wait for it to leave.
            while isHovered, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if !Task.isCancelled {
                onDismiss()
            }
        }
        .kadrAnimation(.snappy(duration: 0.2), value: status.id)
    }

    private var symbol: String {
        status.kind.symbolName
    }

    private var tint: Color {
        status.kind.tint
    }
}
