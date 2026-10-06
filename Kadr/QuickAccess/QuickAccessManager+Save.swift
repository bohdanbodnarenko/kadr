import AppKit
import ControlKit
import MediaExport
import os
import SettingsKit
import Shared
import UniformTypeIdentifiers

/// Overlay Save, including the optional folder picker (CleanShot §6.2 / §7).
///
/// What Save does depends on whose file the card shows (docs/17 T-OUT-5). A capture Kadr
/// wrote is *moved* to where the user wants it. A History copy or a file the user already
/// had is *copied*, under the name the card shows: moving the library's content-addressed
/// blob broke the History row, and "Save" that only hid the card saved nothing.
@MainActor
extension QuickAccessManager {
    func save(_ item: QuickAccessItem) {
        if settings.askForSaveDestination {
            promptSave(item, dismissOnSuccess: true)
            return
        }
        let saved = item.origin.ownsFile ? finalizeIfStaged(item) : saveCopyToFolder(item)
        if saved {
            dismiss(item)
        } else {
            presentSaveFailure(for: item)
        }
    }

    /// Save As always asks where the file should land, even when silent save is on
    /// (CleanShot §6.2).
    func saveAs(_ item: QuickAccessItem) {
        promptSave(item, dismissOnSuccess: true)
    }

    /// The name a save offers: the name the card shows, with the file's real extension.
    ///
    /// The extension comes from the bytes' file, never from the display name, so an HEIC
    /// capture cannot be offered as `name.png` (docs/17 T-OUT-11).
    static func saveFilename(for item: QuickAccessItem) -> String {
        let stem = URL(fileURLWithPath: item.filename).deletingPathExtension().lastPathComponent
        let ext = item.fileURL.pathExtension
        let base = stem.isEmpty ? item.fileURL.deletingPathExtension().lastPathComponent : stem
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Asks where a capture should land (docs/03 §2, docs/17 T-OUT-11).
    ///
    /// Sheet-less and non-modal: `begin`, not `runModal`, so the rest of Kadr — the other
    /// cards, a recording's controls — keeps working while the panel is up. The panel is
    /// restricted to the file's own type with the extension visible, because the bytes are
    /// moved or copied as they are: offering PNG for an HEIC capture wrote HEIC bytes under
    /// a `.png` name.
    ///
    /// Cancel leaves the card and the file as they were. `onCancel` lets a caller with no
    /// card put one up, so a cancelled prompt cannot strand a staged capture.
    func promptSave(
        _ item: QuickAccessItem,
        dismissOnSuccess: Bool = false,
        onCancel: (() -> Void)? = nil
    ) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.saveFilename(for: item)
        panel.directoryURL = settings.saveFolder
        panel.message = String(localized: "Save this capture")
        panel.allowedContentTypes = [item.contentType]
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false

        // An agent app has to be active for its panel to take typing. Hand focus back to
        // whoever had it once the user has answered.
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                defer { Self.returnFocus(to: previous) }
                guard response == .OK, let destination = panel.url else {
                    onCancel?()
                    return
                }
                self?.completeSave(item, to: destination, dismissOnSuccess: dismissOnSuccess)
            }
        }
    }

    private func completeSave(_ item: QuickAccessItem, to destination: URL, dismissOnSuccess: Bool) {
        let live = items.first { $0.id == item.id } ?? item
        guard saveCapture(live, to: destination) != nil else {
            presentFeedback(.failure(
                String(localized: "Couldn't save to \(destination.deletingLastPathComponent().lastPathComponent)"),
                retryTitle: String(localized: "Save As…"),
                retry: { [weak self] in self?.promptSave(live, dismissOnSuccess: dismissOnSuccess) }
            ))
            return
        }
        if dismissOnSuccess {
            dismiss(live)
        }
    }

    /// Asks where a capture that has no card should go (docs/17 T-OUT-3).
    ///
    /// "Ask where to save" with "Show a card" off used to prompt only when a card matched
    /// the file — and with no card, nothing did, so the staged capture waited silently for
    /// the 24-hour sweep. This prompts from the file itself. Cancelling puts a card up
    /// rather than leaving the capture where nobody can see it.
    func promptSave(fileAt url: URL, capturedAt: Date = Date()) {
        if let item = item(matching: url) {
            promptSave(item)
            return
        }
        let item = QuickAccessItem(
            fileURL: url,
            isStaged: output.isStaged(url),
            pixelSize: Self.pixelSize(of: url) ?? PixelSize(width: 0, height: 0),
            scale: Self.scale(of: url),
            capturedAt: capturedAt,
            displayID: nil
        )
        promptSave(item) { [weak self] in
            guard let self, output.isStaged(url) else { return }
            present(item)
        }
    }

    private static func returnFocus(to app: NSRunningApplication?) {
        guard let app, app != NSRunningApplication.current, !app.isTerminated else { return }
        app.activate()
    }

    /// The card currently showing `url`, if any.
    func item(matching url: URL) -> QuickAccessItem? {
        items.first { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
    }

    /// Puts a capture at a path the user picked: moves Kadr's own file, copies anyone
    /// else's. Returns where it landed.
    @discardableResult
    func saveCapture(_ item: QuickAccessItem, to destination: URL) -> URL? {
        guard item.origin.ownsFile else {
            return copyFile(item.fileURL, to: destination)
        }
        return moveCapture(item, to: destination)
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
        // Save As and moves out of staging alike: History follows the file, so Reveal and
        // Pin from History find it where the user put it (docs/18 OUT-6).
        if moved != original {
            history?.noteOriginal(moved)
        }
        return moved
    }

    /// Copies a file Kadr does not own into the save folder under the card's name.
    private func saveCopyToFolder(_ item: QuickAccessItem) -> Bool {
        do {
            let copy = try StagingArea.copy(
                item.fileURL,
                named: Self.saveFilename(for: item),
                into: settings.saveFolder
            )
            logger.info("Saved a copy as \(copy.lastPathComponent, privacy: .private)")
            return true
        } catch {
            logger.error("Could not save a copy: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Keep the card and offer another location when the save folder refused the file
    /// (docs/16 OUT-3).
    func presentSaveFailure(for item: QuickAccessItem, reason: String? = nil) {
        let folder = settings.saveFolder.lastPathComponent
        let message = reason.map { String(localized: "Couldn't save to \(folder): \($0)") }
            ?? String(localized: "Couldn't save to \(folder)")
        presentFeedback(.failure(
            message,
            retryTitle: String(localized: "Save As…")
        ) { [weak self] in
            self?.promptSave(item, dismissOnSuccess: true)
        })
        noteEngagement(with: item)
    }

    func presentSaveFailureCount(_ count: Int) {
        let folder = settings.saveFolder.lastPathComponent
        let message = count == 1
            ? String(localized: "Couldn't save 1 capture to \(folder)")
            : String(localized: "Couldn't save \(count) captures to \(folder)")
        presentFeedback(.failure(message, retryTitle: String(localized: "Save As…")) { [weak self] in
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
            // One step, so a failed move cannot cost the file being replaced.
            return try FileReplacement.move(original, to: destination)
        } catch {
            logger.error("Could not save to the chosen path: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Copies to a path the save panel confirmed, replacing what the user agreed to replace.
    func copyFile(_ source: URL, to destination: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try FileReplacement.copy(source, to: destination)
        } catch {
            logger.error("Could not copy to the chosen path: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
