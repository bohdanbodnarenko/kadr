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
                    KadrText.string("\(KadrPlural.lines(max(recognition.lineCount, 1))) copied")
                )
                presentTextResult(recognition, on: ActiveScreen.resolve())
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
                if !recognition.isEmpty {
                    FeedbackAnnouncement.post(
                        KadrText.string("\(KadrPlural.lines(max(recognition.lineCount, 1))) copied")
                    )
                }

                let screen = ActiveScreen.resolve(displayID: displayID)
                if recognition.isEmpty {
                    if settings.playsCaptureSound {
                        CaptureSound.beep()
                    }
                    presentTextResult(recognition, on: screen)
                    automation.report(.noText)
                    return
                }
                if settings.playsCaptureSound {
                    CaptureSound.play()
                }
                presentTextResult(recognition, on: screen)
                automation.report(.text(recognition.text))
            } catch {
                logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                automation.report(.failed(error.localizedDescription))
                FailurePresenter.present(message: "Kadr could not recognise text in that area.")
            }
        }
    }

    /// The copy has already happened. The toast says so; the review window is for editing.
    ///
    /// The toast is the default answer because the clipboard is the point of Capture Text:
    /// the next thing anyone does is paste, and a window in front of that has to be dismissed
    /// first. Edit is on the toast for the capture that came out wrong, and the review window
    /// still opens straight away for anyone who turns it on in Settings ▸ Capture.
    func presentTextResult(_ recognition: TextRecognizer.Recognition, on screen: NSScreen?) {
        let review = { [weak self] in
            guard let self else { return }
            textReview.show(text: recognition.text, codes: recognition.codes, table: recognition.table)
        }
        if !recognition.text.isEmpty, settings.ocrShowsReview {
            review()
            return
        }
        toast.show(
            text: recognition.text,
            codes: recognition.codes,
            table: recognition.table,
            lineCount: recognition.lineCount,
            on: screen,
            onEdit: review
        )
    }
}
