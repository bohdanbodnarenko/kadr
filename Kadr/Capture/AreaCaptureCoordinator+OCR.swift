import AppKit
import os
import SettingsKit
import Shared

/// OCR of an existing file (`kadr://capture-text?filepath=` — CleanShot §20.6).
@MainActor
extension AreaCaptureCoordinator {
    /// Recognises text in an image on disk, copies it, and reports to automation.
    func recognizeFile(at url: URL) {
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let recognition = try await vision.recognize(
                    fileAt: url,
                    preservingLineBreaks: automation.overrides.preservesLineBreaks
                        ?? settings.ocrPreservesLineBreaks
                )
                vision.copyToClipboard(recognition)
                logger.info("Recognised \(recognition.text.count, privacy: .public) characters from a file")
                toast.show(
                    text: recognition.text,
                    codes: recognition.codes,
                    table: recognition.table,
                    on: NSScreen.main
                )
                automation.report(.text(recognition.text))
            } catch {
                logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                automation.report(.failed(error.localizedDescription))
            }
        }
    }
}
