import AnnotationModel
import AppKit
import Foundation
import os
import Shared
import UniformTypeIdentifiers

/// Opening an image the editor did not capture (docs/09 U1.8).
///
/// Copy, then edit. The alternative — editing a file wherever the user keeps it — means an
/// export can overwrite the original, a Save can land in someone's Photos library, and a
/// file moved mid-session breaks the window. Copying first makes the imported capture
/// behave exactly like one Kadr took: it lives in Kadr's own folder, the original is never
/// touched, and the editor has nothing special to know about where it came from.
@MainActor
struct CaptureImporter {
    private let logger = KadrLog.logger(.app)

    /// The types the editor can open. Also what the app declares to Launch Services.
    static let readableTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]

    /// Where imported captures land: alongside everything else Kadr owns, so the staging
    /// sweep and the history know about them.
    static var importsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Kadr/Imported", isDirectory: true)
    }

    /// Asks for a file and returns Kadr's own copy of it — or, for a `.kadr` project, the
    /// project itself, which is edited in place (T-ED-9).
    func promptForImport() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.readableTypes
            + [UTType(filenameExtension: KadrDocumentFile.fileExtension)].compactMap(\.self)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Kadr copies an image and edits the copy; the original is left alone.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if url.pathExtension.lowercased() == KadrDocumentFile.fileExtension {
            return url
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return copyIntoLibrary(url)
    }

    /// Kadr's copy of `url`, or nil if it could not be made.
    ///
    /// A file already inside the imports folder is returned as-is: re-importing the same
    /// picture twice in a session should not leave two copies.
    func copyIntoLibrary(_ url: URL) -> URL? {
        let directory = Self.importsDirectory
        guard url.standardizedFileURL.deletingLastPathComponent() != directory.standardizedFileURL else {
            return url
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = Self.availableURL(for: url, in: directory)
            try FileManager.default.copyItem(at: url, to: destination)
            logger.info("Imported \(destination.lastPathComponent, privacy: .private)")
            return destination
        } catch {
            logger.error("Could not import an image: \(error.localizedDescription, privacy: .public)")
            present(error, for: url)
            return nil
        }
    }

    /// Deletes imported copies older than `maximumAge`, except the ones open now.
    ///
    /// A copy exists only so a Finder-opened image is never edited in place; once its window
    /// is gone nothing reads it again, and nothing else swept the folder (docs/18 ED-1). The
    /// age keeps a week of crash-recovery copies reachable.
    @discardableResult
    func sweepImports(keeping open: Set<URL>, maximumAge: TimeInterval = 7 * 24 * 60 * 60, now: Date = Date()) -> Int {
        let manager = FileManager.default
        let keep = Set(open.map(\.standardizedFileURL.path))
        guard let entries = try? manager.contentsOfDirectory(
            at: Self.importsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        var removed = 0
        for entry in entries where !keep.contains(entry.standardizedFileURL.path) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > maximumAge else { continue }
            if (try? manager.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            logger.info("Swept \(removed, privacy: .public) imported copies")
        }
        return removed
    }

    /// A free name in `directory`, keeping the original's own name where it can.
    ///
    /// The move itself is the collision check — testing first and copying after is how two
    /// imports in the same second overwrite each other (the docs/07 M6 pattern).
    static func availableURL(for source: URL, in directory: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for counter in 1 ... collisionRetries {
            let name = counter == 1 ? base : "\(base) (\(counter))"
            let candidate = directory.appendingPathComponent(name).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory
            .appendingPathComponent("\(base) \(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    private static let collisionRetries = 32

    private func present(_ error: any Error, for url: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Kadr could not open “\(url.lastPathComponent)”.")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
}
