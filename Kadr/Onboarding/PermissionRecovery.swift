import AppKit
import CaptureCore
import os
import Shared

/// What to do when a capture fails because the grant went away (docs/03 §9).
///
/// macOS 15 asks users to re-confirm screen recording roughly monthly. When they let it
/// lapse, captures start failing — and an app that just does nothing at that point looks
/// broken. This turns the failure into an explanation and two ways forward.
@MainActor
struct PermissionRecovery {
    private let logger = KadrLog.logger(.capture)

    enum Choice {
        case openSettings
        case usePicker
        case dismiss
    }

    /// Shows the recovery alert. Returns what the user chose.
    ///
    /// An alert rather than a sheet: the agent has no window to attach a sheet to, and a
    /// capture that failed needs an answer now rather than the next time a window opens.
    func present(state: ScreenRecordingPermission) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = state == .revoked
            ? "macOS has asked you to re-confirm screen recording."
            : "Kadr does not have permission to record the screen."
        alert.informativeText = state == .revoked
            ? "macOS asks about once a month, for every screen-capture app. Turn Kadr back "
            + "on and captures will work again."
            : "Turn Kadr on under Privacy & Security → Screen & System Audio Recording. "
            + "You can also capture a window through the macOS picker, which needs no permission."

        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Use the macOS Picker")
        alert.addButton(withTitle: "Later")

        // An accessory app has to come forward for a modal, or the alert appears behind
        // whatever the user was doing.
        NSApp.activate()

        return switch alert.runModal() {
        case .alertFirstButtonReturn: .openSettings
        case .alertSecondButtonReturn: .usePicker
        default: .dismiss
        }
    }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
