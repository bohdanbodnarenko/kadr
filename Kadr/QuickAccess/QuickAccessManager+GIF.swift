import AppKit
import Foundation
import os
import OverlayKit
import SettingsKit
import Shared

/// GIF export from a recording card (docs/03 §1.8, CleanShot §13.6).
@MainActor
extension QuickAccessManager {
    func exportGIF(_ item: QuickAccessItem) {
        exportGIF(item, confirm: true)
    }

    /// Turns a recording into a GIF. Dedicated GIF capture skips the confirm unless
    /// the encoder had to clip the take (docs/03 §1.8, CleanShot §13.6).
    ///
    /// The encode happens in the helper process, so the agent never holds a single frame
    /// of it (docs/04 §1).
    func exportGIF(_ item: QuickAccessItem, confirm: Bool) {
        let destination = Self.freeGIFDestination(for: item, saveFolder: settings.saveFolder)
        setActivity(.exportingGIF, on: item)
        Task { [weak self] in
            guard let self else { return }
            defer { vision.disconnect() }
            // Busy while encoding, so auto-dismiss cannot take the card mid-export
            // (docs/16 OUT-16).
            defer { setActivity(nil, on: item) }

            do {
                let estimate = try await vision.encodeGIF(GIFRequest(
                    sourcePath: item.fileURL.path,
                    destinationPath: destination.path,
                    estimateOnly: true
                ))
                if confirm || estimate.isClipped {
                    guard confirmExport(estimate) else { return }
                }

                let result = try await vision.encodeGIF(GIFRequest(
                    sourcePath: item.fileURL.path,
                    destinationPath: destination.path
                ))
                guard let path = result.path else { return }
                let gifURL = URL(fileURLWithPath: path)
                logger.info("Exported \(gifURL.lastPathComponent, privacy: .private)")
                presentExternalFile(at: gifURL, origin: .capture)
                NSWorkspace.shared.activateFileViewerSelecting([gifURL])
            } catch {
                logger.error("GIF export failed: \(error.localizedDescription, privacy: .public)")
                presentFeedback(.failure(
                    String(localized: "GIF export failed"),
                    retryTitle: String(localized: "Retry"),
                    retry: { [weak self] in self?.exportGIF(item, confirm: confirm) }
                ))
            }
        }
    }

    /// Where the GIF goes: beside a capture Kadr made, in the save folder for anything
    /// else, and never over an existing file (docs/17 T-OUT-13). A History card's file
    /// sits in the library, which is no place for an export.
    static func freeGIFDestination(for item: QuickAccessItem, saveFolder: URL? = nil) -> URL {
        let stem = URL(fileURLWithPath: item.filename).deletingPathExtension().lastPathComponent
        let folder = item.origin.ownsFile
            ? item.fileURL.deletingLastPathComponent()
            : (saveFolder ?? item.fileURL.deletingLastPathComponent())
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension("gif")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) (\(counter))").appendingPathExtension("gif")
            counter += 1
        }
        return candidate
    }

    /// Shows the estimate before committing, because a large GIF takes real time to make.
    ///
    /// The estimate carries the plan the encoder settled on, so a recording too long to
    /// hold in memory says so here rather than silently producing a shorter GIF than the
    /// user expected (docs/07 M10).
    func confirmExport(_ estimate: GIFResponse) -> Bool {
        let size = ByteCountFormatter.string(fromByteCount: Int64(estimate.byteCount), countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Export this recording as a GIF?"
        var detail = "The GIF will be roughly \(size). GIFs are much larger than "
            + "video, so long recordings get big quickly."
        if estimate.isClipped {
            let seconds = Int(estimate.encodedSeconds.rounded())
            detail += "\n\nThis recording is too long to turn into one GIF, so the export "
                + "will cover the first \(seconds) seconds. Trim it first to choose which part."
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        let answer = ActivationJuggler.shared.withTemporaryActivation(
            returningTo: ActivationJuggler.returnTarget()
        ) { alert.runModal() }
        return answer == .alertFirstButtonReturn
    }
}
