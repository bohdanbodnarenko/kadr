import AppKit
import MediaExport
import os
import SettingsKit
import Shared
import UniformTypeIdentifiers

/// Overlay Save, including the optional folder picker (CleanShot §6.2 / §7).
@MainActor
extension QuickAccessManager {
    func save(_ item: QuickAccessItem) {
        if settings.askForSaveDestination {
            promptSave(item, dismissOnSuccess: true)
            return
        }
        if finalizeIfStaged(item) {
            dismiss(item)
        } else {
            presentSaveFailure(for: item)
        }
    }

    /// Save As always asks where the file should land, even when silent save is on
    /// (CleanShot §6.2).
    func saveAs(_ item: QuickAccessItem) {
        _ = promptSave(item, dismissOnSuccess: true)
    }

    /// Asks where a capture should land.
    ///
    /// Cancel leaves the card and the staged file as they were. Confirming moves the
    /// file (and its sibling `.kadr`) to the path the panel named.
    @discardableResult
    func promptSave(_ item: QuickAccessItem, dismissOnSuccess: Bool = false) -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = item.fileURL.deletingPathExtension().lastPathComponent
        panel.directoryURL = settings.saveFolder
        panel.message = "Save this capture"
        if item.isVideo {
            panel.allowedContentTypes = [.mpeg4Movie]
        } else {
            panel.allowedContentTypes = ImageFormat.writable.map(\.contentType)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        guard moveCapture(item, to: destination) != nil else { return false }
        if dismissOnSuccess {
            dismiss(item)
        }
        return true
    }

    /// The card currently showing `url`, if any.
    func item(matching url: URL) -> QuickAccessItem? {
        items.first { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
    }

    /// Moves a capture to a path the user picked, keeping the project file beside it.
    @discardableResult
    func moveCapture(_ item: QuickAccessItem, to destination: URL) -> URL? {
        let original = item.fileURL
        let moved: URL? = if item.isStaged, output.isStaged(original) {
            output.finalizeStaged(original, to: destination)
        } else if original.standardizedFileURL == destination.standardizedFileURL {
            original
        } else {
            moveFile(original, to: destination)
        }
        guard let moved else { return nil }
        CaptureProject.move(from: original, to: moved)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].fileURL = moved
            items[index].isStaged = false
        }
        return moved
    }

    /// Keep the card and offer another location when the save folder refused the file
    /// (docs/16 OUT-3).
    func presentSaveFailure(for item: QuickAccessItem) {
        let folder = settings.saveFolder.lastPathComponent
        presentFeedback(.failure(
            "Couldn't save to \(folder)",
            retryTitle: "Save As…"
        ) { [weak self] in
            self?.promptSave(item, dismissOnSuccess: true)
        })
        noteEngagement(with: item)
    }

    func presentSaveFailureCount(_ count: Int) {
        let folder = settings.saveFolder.lastPathComponent
        let message = count == 1
            ? "Couldn't save 1 capture to \(folder)"
            : "Couldn't save \(count) captures to \(folder)"
        presentFeedback(.failure(message, retryTitle: "Save As…") { [weak self] in
            guard let self, let item = unsavedItems.first else { return }
            promptSave(item, dismissOnSuccess: true)
        })
    }

    func moveFile(_ original: URL, to destination: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: original, to: destination)
            return destination
        } catch {
            logger.error("Could not save to the chosen path: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
