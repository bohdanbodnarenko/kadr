import AppKit
import Foundation
import HistoryKit
import Shared

/// What the coordinator hands to the Quick Access Overlay and the pins (docs/03 §2, §4).
///
/// Forwarders, deliberately kept together and out of the capture flow: they are the
/// coordinator's public surface for everything that happens to a capture *after* it
/// exists — the menu's "restore", the history window's re-open, and the automation verbs
/// that name a file (docs/03 §8.4).
extension AreaCaptureCoordinator {
    /// Brings back the most recently dismissed card, or the latest history item (docs/03 §5).
    func restoreRecentlyClosed() {
        quickAccess.restoreRecentlyClosed()
    }

    var canRestoreRecentlyClosed: Bool {
        quickAccess.hasRecentlyClosed
    }

    /// Re-opens a library item as a Quick Access card (docs/03 §5).
    func reopenFromHistory(_ record: HistoryRecord) {
        quickAccess.presentFromHistory(record)
    }

    /// Opens a recording in the studio when a session still exists, otherwise the overlay.
    func openFromHistory(_ record: HistoryRecord) {
        quickAccess.openFromHistory(record)
    }

    /// Pins a file automation named (docs/03 §8.4). Returns false when it is not an image.
    @discardableResult
    func pinFile(at url: URL) -> Bool {
        quickAccess.pinFile(at: url)
    }

    /// Opens a file automation named in the editor (docs/03 §8.4).
    func annotateFile(at url: URL) {
        quickAccess.annotateFile(at: url)
    }

    /// The "Close all pins" global command (docs/03 §4).
    func closeAllPins() {
        pins.closeAll()
    }

    var pinCount: Int {
        pins.count
    }

    /// Puts a stitched scrolling capture into the overlay and the editor (docs/03 §1.6).
    func showScrollingCapture(at fileURL: URL, pixelSize: PixelSize) {
        quickAccess.showScrollingCapture(at: fileURL, pixelSize: pixelSize)
    }

    /// Puts a finished recording into the Quick Access Overlay (docs/03 §1.8).
    func showRecording(at fileURL: URL) {
        quickAccess.showRecording(at: fileURL)
    }
}
