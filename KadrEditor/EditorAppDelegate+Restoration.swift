import AppKit
import EditorUI

/// Reopening windows and offering recovered edits at launch (docs/18 T-ED-7).
extension EditorAppDelegate {
    /// Runs after the launch's own documents have been opened: they arrive through
    /// `application(_:open:)` around the end of launching, and must not be offered as
    /// recoveries or opened twice.
    func restoreWindowsAfterLaunch() {
        // A test host must not reopen the developer's captures or stop on a modal alert.
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil, environment["XCTestBundlePath"] == nil else {
            return
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.restoreWindows()
        }
    }

    func rememberOpenWindowsForNextLaunch() {
        EditorRestoration().remember(restorableDocuments)
    }

    private func restoreWindows() {
        let autosave = EditorAutosave()
        let plan = EditorRestoration.plan(
            restorable: EditorRestoration().takeRestorable(),
            recoveries: autosave.pendingRecoveries(),
            open: Set(restorableDocuments)
        )
        for url in plan.reopen {
            openDocument(url)
        }
        guard !plan.offer.isEmpty else { return }
        offerRecoveries(plan.offer, autosave: autosave)
    }

    /// One alert for every capture with recoverable edits, instead of finding out only
    /// by happening to reopen the right one. Reopening hands each to its own window, which
    /// asks about its recovery as it always has.
    private func offerRecoveries(_ captures: [URL], autosave: EditorAutosave) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = captures.count == 1
            ? String(localized: "Kadr kept unsaved edits for “\(captures[0].lastPathComponent)”.")
            : String(localized: "Kadr kept unsaved edits for \(captures.count) captures.")
        let names = captures.prefix(8).map { "• \($0.lastPathComponent)" }.joined(separator: "\n")
        let more = captures.count > 8
            ? "\n" + String(localized: "and \(captures.count - 8) more")
            : ""
        alert.informativeText = captures.count == 1
            ? String(localized: "Reopen it to review the edits, or discard them.")
            : names + more
        alert.addButton(withTitle: String(localized: "Reopen"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        let discard = alert.addButton(withTitle: String(localized: "Discard Edits"))
        discard.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            captures.forEach(openDocument)
        case .alertThirdButtonReturn:
            captures.forEach(autosave.discard(for:))
        default:
            break
        }
    }
}
