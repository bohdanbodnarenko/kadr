import AnnotationModel
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
        let prepared = captures.map { FullscreenNotchCropper.apply($0, settings: settings) }
        let delivered = await output.deliverOffMain(prepared, overrides: automation.overrides)
        let spec = autoBeautifySpec()
        for entry in delivered {
            presentCapture(entry.result, capture: entry.capture)
        }
        guard let first = delivered.first else {
            reportDeliveryFailure()
            return
        }
        // Some displays wrote and some did not: say so rather than drop them (T-OUT-6).
        if delivered.count < prepared.count {
            reportExportFailure(missing: prepared.count - delivered.count)
        }
        // One sound for one action, however many displays it took (T-CAP-4).
        playCaptureSound()
        for entry in delivered {
            await writeBeautifyProject(alongside: entry.result.fileURL, original: entry.capture, beautify: spec)
        }
        // The captures arrive active display first (`ordered(_:preferringActive:)`), so the
        // after-capture actions follow the display the user is on, once.
        finishDelivery(of: first.result.fileURL)
    }

    /// Displays of a multi-display capture that could not be written anywhere — not the
    /// save folder, not staging — must never be dropped silently (docs/17 T-OUT-6).
    func reportExportFailure(missing count: Int) {
        let message = count == 1
            ? String(localized: "Couldn't save one display's capture")
            : String(localized: "Couldn't save \(count) displays' captures")
        FailurePresenter.report(message, detail: "export returned no file", logger: logger)
    }

    /// Exports a capture and puts a card up for it (docs/03 §2).
    ///
    /// Async because the encode happens off the main actor: a 5K PNG is hundreds of
    /// milliseconds of CPU, and doing it here froze every window and blew the
    /// selection→clipboard budget this path's own signpost measures (docs/07 H4).
    ///
    /// `beautify` is window-capture chrome or a stills preset. When omitted, the
    /// capture-pane auto-beautify setting applies unless Shift skipped it.
    func deliver(
        _ capture: Capture,
        editableOriginal: Capture? = nil,
        beautify: BeautifySpec? = nil
    ) async {
        let prepared = FullscreenNotchCropper.apply(capture, settings: settings)
        let preparedOriginal = editableOriginal.map { FullscreenNotchCropper.apply($0, settings: settings) }
        guard let result = await output.deliverOffMain(prepared, overrides: automation.overrides) else {
            reportDeliveryFailure()
            return
        }
        presentCapture(result, capture: prepared)
        playCaptureSound()
        await writeBeautifyProject(
            alongside: result.fileURL,
            original: preparedOriginal ?? prepared,
            beautify: beautify ?? autoBeautifySpec()
        )
        finishDelivery(of: result.fileURL)
    }

    private func playCaptureSound() {
        if settings.playsCaptureSound, automation.overrides.isEmpty {
            CaptureSound.play()
        }
    }

    /// The export or the disk failed: say so, not only in the log (T-CAP-6).
    func reportDeliveryFailure() {
        let message = "Kadr could not write the capture."
        automation.report(.failed(message))
        FailurePresenter.present(message: "\(message) Check that the save folder exists and the disk has room.")
    }

    /// What every delivery does once its file exists: the automation action or the
    /// after-capture actions, then the reply.
    private func finishDelivery(of fileURL: URL?) {
        if let fileURL {
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
        let outcome = fileURL.map(CaptureOutcome.file)
        automation.report(outcome ?? .failed("Kadr could not write the capture."))
    }

    /// Puts a card up when the matrix asks for one; otherwise History still gets the file.
    ///
    /// A save folder that refused the file (unmounted drive, read-only, full) still gets a
    /// card, whatever the matrix says: the capture was staged instead, and the card is
    /// where "Couldn't save to X — Save As…" can be answered (docs/17 T-OUT-6).
    func presentCapture(_ result: ExportResult, capture: Capture) {
        if let reason = result.saveFailure {
            quickAccess.show(result, capture: capture)
            if let fileURL = result.fileURL, let item = quickAccess.item(matching: fileURL) {
                quickAccess.presentSaveFailure(for: item, reason: reason)
            }
            return
        }
        if settings.afterCaptureActions(for: .screenshot).contains(.overlay) {
            quickAccess.show(result, capture: capture)
        } else {
            quickAccess.ingestWithoutCard(result, capture: capture)
        }
    }

    func autoBeautifySpec() -> BeautifySpec? {
        skipAutoBeautify ? nil : AutoBeautify.spec(for: settings.autoBeautifyPreset)
    }

    func writeBeautifyProject(alongside fileURL: URL?, original: Capture, beautify: BeautifySpec?) async {
        guard let fileURL else { return }
        await CaptureProject.writeOffMain(original: original, beautify: beautify, alongside: fileURL)
    }

    /// Runs the after-capture actions the settings ask for (docs/09 U2.2).
    ///
    /// Only the ones that say what to do *with* the file: whether it was copied or saved
    /// was already decided by the export policy, because those choices have to be made
    /// before the bytes are written rather than after.
    func applyAfterCaptureActions(to fileURL: URL) {
        let actions = settings.afterCaptureActions(for: .screenshot)
        if actions.contains(.promptSave) {
            // From the file, not the card: with "Show a card" off there is no card, and
            // waiting for one lost the capture (docs/17 T-OUT-3).
            quickAccess.promptSave(fileAt: fileURL)
        }
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
        // will keep failing until they act (docs/03 §9). Everything else — a window closed
        // during the countdown, a display gone, an SCK error — gets a banner rather than
        // only a log line (T-CAP-6).
        guard mapped.indicatesPermissionLoss else {
            FailurePresenter.present(message: mapped.errorDescription ?? "The capture failed.")
            return
        }
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
