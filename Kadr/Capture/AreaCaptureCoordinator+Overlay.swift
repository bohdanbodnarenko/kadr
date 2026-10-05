import AppKit
import Foundation
import HistoryKit
import OverlayKit
import Shared
import UniformTypeIdentifiers

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

    /// Puts an existing file on the overlay (CleanShot `add-quick-access-overlay`).
    @discardableResult
    func presentExternalFile(at url: URL) -> Bool {
        quickAccess.presentExternalFile(at: url)
    }

    /// Opens the clipboard as a Quick Access card (CleanShot `open-from-clipboard`).
    @discardableResult
    func presentFromClipboard() -> Bool {
        quickAccess.presentFromClipboard()
    }

    /// Pins the clipboard as a reference window: an image, or text drawn as a card.
    @discardableResult
    func pinClipboard() -> Bool {
        quickAccess.pinClipboard()
    }

    /// Pins a file chosen from an open panel, for `kadr pin` with no path.
    @discardableResult
    func pinFromOpenPanel() -> URL? {
        ActivationJuggler.shared.beginRegularWindow()
        defer { ActivationJuggler.shared.endRegularWindow() }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Pin")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return pinFile(at: url) ? url : nil
    }

    /// The "Close all pins" global command (docs/03 §4).
    func closeAllPins() {
        pins.closeAll()
    }

    func togglePinsHidden() {
        pins.toggleHidden()
    }

    var pinsAreHidden: Bool {
        pins.isHidden
    }

    /// Reopens pins that were showing when Kadr last quit (docs/03 §4 P2).
    func restorePersistedPins() {
        pins.restore(
            copy: { [weak self] url in self?.quickAccess.copyFile(at: url) },
            save: { [weak self] url in self?.quickAccess.saveCopy(of: url) },
            annotate: { [weak self] url in self?.quickAccess.openInEditor(url) },
            copyText: { [weak self] url in self?.quickAccess.recognizeText(at: url) },
            reveal: { [weak self] url in self?.quickAccess.revealInFinder(url) }
        )
    }

    func closeAllOverlays() {
        quickAccess.dismissAll()
    }

    func saveAllOverlays() {
        quickAccess.saveAll()
    }

    func toggleOverlaysHidden() {
        quickAccess.toggleHidden()
    }

    var overlaysAreHidden: Bool {
        quickAccess.areHidden
    }

    var overlayCardCount: Int {
        quickAccess.items.count
    }

    var pinCount: Int {
        pins.count
    }

    /// Puts a stitched scrolling capture into the overlay and the editor (docs/03 §1.6).
    func showScrollingCapture(at fileURL: URL, pixelSize: PixelSize) {
        quickAccess.showScrollingCapture(at: fileURL, pixelSize: pixelSize)
    }

    /// Puts a finished recording into the Quick Access Overlay (docs/03 §1.8).
    func showRecording(at fileURL: URL, exportGIF: Bool = false) {
        quickAccess.showRecording(at: fileURL, exportGIF: exportGIF)
    }
}
