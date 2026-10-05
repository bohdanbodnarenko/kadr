import Foundation
import HistoryKit
import SettingsKit
import Shared

/// Captures the editor saved, so the card, History and clipboard stay current (docs/16 OUT-4).
@MainActor
extension QuickAccessManager {
    func watchForEditorSaves() {
        guard editorSaveObserver == nil else { return }
        editorSaveObserver = DistributedNotificationCenter.default().addObserver(
            forName: CaptureSavedNotice.name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let paths = CaptureSavedNotice.decode(notification.object) else { return }
            MainActor.assumeIsolated {
                self?.captureWasSaved(paths)
            }
        }
    }

    func captureWasSaved(_ paths: CaptureSavedNotice.Paths) {
        guard paths.isValid(saveFolder: settings.saveFolder) else { return }
        // A sibling `.kadr` is the re-editable sidecar, not a second capture.
        guard paths.saved.pathExtension.lowercased() != "kadr" else { return }

        let original = paths.original.standardizedFileURL
        let saved = paths.saved.standardizedFileURL
        let overwritten = original == saved

        var card: QuickAccessItem?
        if let index = items.firstIndex(where: {
            $0.fileURL.standardizedFileURL == original || $0.fileURL.standardizedFileURL == saved
        }) {
            card = items[index]
            items[index].fileURL = saved
            if let size = Self.pixelSize(of: saved) {
                items[index].pixelSize = size
            }
            items[index].contentRevision += 1
            items[index].isStaged = false
        }

        // The History row keeps what it knew: the capture date and app come from the card
        // when there is one, and a save over the file replaces the row's content instead of
        // deleting it and ingesting a capture dated now (docs/18 OUT-4).
        let ingest = HistoryIngest(
            sourceURL: saved,
            kind: .image,
            pixelSize: Self.pixelSize(of: saved) ?? PixelSize(width: 0, height: 0),
            applicationName: card?.applicationName,
            capturedAt: card?.capturedAt ?? Date(),
            originalFilename: saved.lastPathComponent
        )
        if overwritten {
            history?.replaceContent(previousHash: paths.previousHash, content: ingest, ingestIfMissing: true)
        } else {
            history?.ingest(ingest)
        }

        if settings.afterCaptureActions(for: .screenshot).contains(.copy) {
            copyFile(at: saved)
        }
    }
}
