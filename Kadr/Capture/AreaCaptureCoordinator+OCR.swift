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
                FeedbackAnnouncement.post(
                    KadrText.string("Text copied, \(recognition.text.count) characters")
                )
                presentTextResult(
                    recognition.text,
                    codes: recognition.codes,
                    table: recognition.table,
                    on: ActiveScreen.resolve()
                )
                if recognition.isEmpty {
                    if settings.playsCaptureSound {
                        CaptureSound.beep()
                    }
                    automation.report(.noText)
                } else {
                    if settings.playsCaptureSound {
                        CaptureSound.play()
                    }
                    automation.report(.text(recognition.text))
                }
            } catch {
                logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                FeedbackAnnouncement.post(ActionUnavailableReason.couldNotReadText.message)
                automation.report(.failed(error.localizedDescription))
            }
        }
    }

    /// Sends a crop to the Vision helper and puts the result on the clipboard.
    func recognizeText(in image: CGImage, on displayID: CGDirectDisplayID) {
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let recognition = try await vision.recognize(
                    image,
                    preservingLineBreaks: automation.overrides.preservesLineBreaks
                        ?? settings.ocrPreservesLineBreaks
                )
                vision.copyToClipboard(recognition)
                let characters = recognition.text.count
                logger.info("Recognised \(characters, privacy: .public) characters")

                let screen = ActiveScreen.resolve(displayID: displayID)
                if recognition.isEmpty {
                    if settings.playsCaptureSound {
                        CaptureSound.beep()
                    }
                    presentTextResult("", codes: recognition.codes, table: recognition.table, on: screen)
                    automation.report(.noText)
                    return
                }
                if settings.playsCaptureSound {
                    CaptureSound.play()
                }
                presentTextResult(
                    recognition.text,
                    codes: recognition.codes,
                    table: recognition.table,
                    on: screen
                )
                automation.report(.text(recognition.text))
            } catch {
                logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                automation.report(.failed(error.localizedDescription))
            }
        }
    }

    /// Copies already happened. The toast confirms; the review window is for editing.
    func presentTextResult(
        _ text: String,
        codes: [DetectedCode],
        table: RecognizedTable?,
        on screen: NSScreen?
    ) {
        if text.isEmpty {
            toast.show(text: text, codes: codes, table: table, on: screen)
            return
        }
        if settings.ocrShowsReview {
            textReview.show(text: text, codes: codes, table: table)
        } else {
            toast.show(text: text, codes: codes, table: table, on: screen)
        }
    }
}
