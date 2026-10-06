import AppKit
import HistoryKit
import os
import Shared

/// Export Diagnostics, Report a Problem and the launch record (docs/17 T-DIAG-1, T-DIAG-4).
extension AppDelegate {
    static let lastLaunchedBuildKey = "com.bohdanbodnarenko.kadr.lastLaunchedBuild"

    /// Logs the version at `.notice`, so it survives in the unified log, and notes an
    /// upgrade — the hook a later "What's New" will hang off.
    func recordLaunch(defaults: UserDefaults = .standard) {
        let identity = BuildIdentity.current
        let current = identity.displayString
        let previous = defaults.string(forKey: Self.lastLaunchedBuildKey)
        let location = RunLocation.classify(bundlePath: Bundle.main.bundlePath).rawValue
        logger.notice("Kadr \(current, privacy: .public) launched from \(location, privacy: .public)")
        if let previous, previous != current {
            logger.notice("Upgraded from \(previous, privacy: .public) to \(current, privacy: .public)")
        }
        defaults.set(current, forKey: Self.lastLaunchedBuildKey)
    }

    /// The snapshot as of now. Cheap: everything slow happens in the exporter.
    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        let conflicts = hotkeyCenter?.health.conflicts ?? [:]
        var hotkeys: [String: String] = [:]
        for (command, reason) in conflicts {
            hotkeys[command.rawValue] = reason
        }
        return DiagnosticsSnapshot.collect(
            hotkeyConflicts: hotkeys,
            loginItem: String(describing: loginItemState),
            historyItemCount: history.usage.itemCount
        )
    }

    /// Help ▸ Export Diagnostics…: writes the zip and shows it in Finder.
    @discardableResult
    func exportDiagnostics(reveal: Bool = true) async -> URL? {
        do {
            let url = try await DiagnosticsExporter.export(snapshot: diagnosticsSnapshot())
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return url
        } catch {
            logger.error("Exporting diagnostics failed: \(error.localizedDescription, privacy: .public)")
            FailurePresenter
                .present(message: String(localized: "Kadr could not export diagnostics. \(error.localizedDescription)"))
            return nil
        }
    }

    /// Help ▸ Report a Problem…: the zip first, so it is sitting in Finder by the time the
    /// issue form asks for it, then the prefilled form in the browser.
    func reportProblem() async {
        guard await exportDiagnostics(reveal: true) != nil else { return }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        guard let url = ProblemReport.url(for: .current, macOS: macOS) else { return }
        logger.notice("Opening the problem report form")
        NSWorkspace.shared.open(url)
    }

    /// Settings ▸ Updates ▸ Copy Diagnostic Summary.
    func copyDiagnosticSummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsSnapshot().summaryText, forType: .string)
    }
}
