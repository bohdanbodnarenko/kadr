import AppKit
import AutomationKit
import CaptureCore
import HistoryKit
import MediaExport
import os
import OverlayKit
import SelectionUI
import SettingsKit
import Shared

/// What happens once a capture exists: export, card, automation reply — and what happens
/// when it does not (docs/03 §2, §8.4, §9).
///
/// Split from the coordinator's own file because the capture *paths* and the delivery
/// *policy* change for different reasons; the file was also over its length budget.
@MainActor
extension AreaCaptureCoordinator {
    /// Exports every display captured by one action (docs/07 M4).
    func deliverAll(_ captures: [Capture]) async {
        let delivered = await output.deliverOffMain(captures, overrides: automation.overrides)
        for entry in delivered {
            quickAccess.show(entry.result, capture: entry.capture)
        }
        let first = delivered.first?.result.fileURL
        automation.report(first.map(CaptureOutcome.file) ?? .failed("Kadr could not write the capture."))
    }

    /// Exports a capture and puts a card up for it (docs/03 §2).
    ///
    /// Async because the encode happens off the main actor: a 5K PNG is hundreds of
    /// milliseconds of CPU, and doing it here froze every window and blew the
    /// selection→clipboard budget this path's own signpost measures (docs/07 H4).
    func deliver(_ capture: Capture) async {
        guard let result = await output.deliverOffMain(capture, overrides: automation.overrides) else {
            automation.report(.failed("Kadr could not write the capture."))
            return
        }
        quickAccess.show(result, capture: capture)

        if let fileURL = result.fileURL {
            // `action=annotate|pin` says what to do with the file once it exists
            // (docs/03 §8.4). An automated request overrides the setting for this capture
            // only, so the matrix is consulted just when nobody asked for anything.
            switch automation.overrides.action {
            case .annotate: quickAccess.annotateFile(at: fileURL)
            case .pin: quickAccess.pinFile(at: fileURL)
            // Exhaustive rather than `default: break` (docs/11 S2). `copy`, `save` and
            // `overlay` are decided by the export policy before the bytes are written, so
            // by the time the file exists there is genuinely nothing left to do — but that
            // is a fact worth stating, because `default` would have swallowed the *next*
            // case just as quietly and it would have appeared enabled and done nothing.
            case .copy, .save, .overlay: break
            case .none: applyAfterCaptureActions(to: fileURL)
            }
        }
        let outcome = result.fileURL.map(CaptureOutcome.file)
        automation.report(outcome ?? .failed("Kadr could not write the capture."))
    }

    /// Runs the after-capture actions the settings ask for (docs/09 U2.2).
    ///
    /// Only the ones that say what to do *with* the file: whether it was copied or saved
    /// was already decided by the export policy, because those choices have to be made
    /// before the bytes are written rather than after.
    func applyAfterCaptureActions(to fileURL: URL) {
        let actions = settings.afterCaptureActions(for: .screenshot)
        if actions.contains(.annotate) {
            quickAccess.annotateFile(at: fileURL)
        }
        if actions.contains(.pin) {
            quickAccess.pinFile(at: fileURL)
        }
    }

    func handle(_ error: any Error) {
        if error is CancellationError {
            // Deliberately silent: a cancelled task means a *newer* capture superseded
            // this one, and by now the automation slot belongs to that one. Arming
            // reports the cancellation to whoever was displaced (docs/06 M19).
            return
        }
        permissions.noteCaptureFailure(error)
        let mapped = CaptureError.mapping(error)
        automation.report(.failed(mapped.errorDescription ?? "Capture failed."))
        logger.error("Capture failed: \(mapped.errorDescription ?? "unknown", privacy: .public)")

        // A lost grant is the one failure worth interrupting the user over: every capture
        // will keep failing until they act (docs/03 §9).
        guard mapped.indicatesPermissionLoss else { return }
        switch recovery.present(state: permissions.state) {
        case .openSettings:
            recovery.openSystemSettings()
        case .usePicker:
            captureWithSystemPicker()
        case .dismiss:
            break
        }
    }
}
