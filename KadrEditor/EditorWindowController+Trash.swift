import AnnotationModel
import AppKit
import EditorUI
import os
import Shared

/// Delete, from the editor: the capture and its project go to the Trash (docs/03 §3).
///
/// To the Trash, never removed outright, and only after asking — the editor is where a
/// capture has had the most work put into it, and the Trash is how that work comes back.
extension EditorWindowController {
    /// What deleting this capture moves: the image, and the `.kadr` project beside it.
    ///
    /// Either may be what the window opened. The image's path is the one that matters to
    /// the agent, because that is what its overlay card points at.
    struct TrashableCapture {
        var image: URL?
        var project: URL?

        var displayName: String {
            (image ?? project)?.lastPathComponent ?? "this capture"
        }
    }

    private static let imageExtensions = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"]

    func trashableCapture() -> TrashableCapture {
        let files = FileManager.default
        if fileURL.pathExtension.lowercased() == KadrDocumentFile.fileExtension {
            let base = fileURL.deletingPathExtension()
            let image = Self.imageExtensions
                .flatMap { [$0, $0.uppercased()] }
                .map { base.appendingPathExtension($0) }
                .first { files.fileExists(atPath: $0.path) }
            return TrashableCapture(image: image, project: fileURL)
        }
        let project = fileURL.deletingPathExtension().appendingPathExtension(KadrDocumentFile.fileExtension)
        return TrashableCapture(
            image: fileURL,
            project: files.fileExists(atPath: project.path) ? project : nil
        )
    }

    /// Asks, then moves the capture to the Trash and closes the window.
    func confirmMoveToTrash() {
        guard let window else { return }
        let capture = trashableCapture()

        let alert = NSAlert()
        alert.messageText = "Move “\(capture.displayName)” to the Trash?"
        alert.informativeText = capture.image != nil && capture.project != nil
            ? "Its editable project moves to the Trash too. You can put both back from the Trash."
            : "You can put it back from the Trash."
        let trashButton = alert.addButton(withTitle: "Move to Trash")
        trashButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let responder = FocusRestoration.capture(from: window)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                FocusRestoration.restore(responder, in: window)
                return
            }
            moveToTrash(capture)
        }
    }

    private func moveToTrash(_ capture: TrashableCapture) {
        let files = FileManager.default
        do {
            if let image = capture.image {
                var resulting: NSURL?
                try files.trashItem(at: image, resultingItemURL: &resulting)
                if let trashed = resulting as URL? {
                    CaptureDeletionNotice.post(.init(original: image, trashed: trashed))
                }
            }
            if let project = capture.project, files.fileExists(atPath: project.path) {
                try files.trashItem(at: project, resultingItemURL: nil)
            }
        } catch {
            logger.error("Could not move to the Trash: \(error.localizedDescription, privacy: .public)")
            if let window {
                NSAlert(error: error).beginSheetModal(for: window)
            }
            return
        }

        logger.info("Moved \(capture.displayName, privacy: .public) to the Trash")
        autosave.discard(for: fileURL)
        // The work is in the Trash, not lost, so the unsaved-changes question does not apply.
        isClosingConfirmed = true
        window?.close()
    }
}
