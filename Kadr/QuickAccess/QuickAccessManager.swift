import AppKit
import CaptureCore
import HistoryKit
import MediaExport
import os
import OverlayKit
import SettingsKit
import Shared
import UniformTypeIdentifiers

/// Owns the Quick Access Overlay: the cards, where they sit, and when they go away.
///
/// This is the surface doc 03 §2 calls the product, so its rules are worth stating:
/// cards never take focus, they stack with the newest in front, they sit inside the
/// screen's visible frame so they never cover the Dock, and dismissing a card is not
/// the same as deleting its file.
/// Several members are internal rather than private: the card actions live in
/// `QuickAccessManager+Actions.swift`, and `private` is file-scoped.
@MainActor
final class QuickAccessManager {
    let settings: AppSettings
    let output: CaptureOutput
    let pins: PinManager
    let editor = EditorLauncher()
    /// The helper does the GIF encoding; the agent only asks for it (docs/04 §1).
    /// The helper connection for GIF encoding (docs/03 §1.8).
    let vision = VisionClient()
    let textRecognizer = TextRecognizer()
    /// Shows what OCR found, the same panel the selection overlay's text mode uses.
    let textToast = TextCaptureToast()
    let history: HistoryController?
    let logger = KadrLog.logger(.overlay)

    var panels: [(item: QuickAccessItem, panel: QuickAccessPanel)] = []
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    /// Dismissed cards, newest first, for "Restore Recently Closed" (docs/03 §2).
    private var recentlyClosed: [QuickAccessItem] = []

    private static let cardSpacing: CGFloat = 12
    private static let screenMargin: CGFloat = 16
    private static let maximumRecentlyClosed = 10

    init(settings: AppSettings, output: CaptureOutput, pins: PinManager, history: HistoryController? = nil) {
        self.settings = settings
        self.output = output
        self.pins = pins
        self.history = history
    }

    var hasRecentlyClosed: Bool {
        !recentlyClosed.isEmpty
    }

    /// The cards currently on screen, newest first.
    var items: [QuickAccessItem] {
        panels.map(\.item)
    }

    /// Shows a card for a capture that has just been exported.
    func show(_ result: ExportResult, capture: Capture) {
        guard let fileURL = result.fileURL else {
            logger.error("A capture reached the overlay with no file to show")
            return
        }

        let item = QuickAccessItem(
            fileURL: fileURL,
            isStaged: result.isStaged,
            pixelSize: capture.metadata.pixelSize,
            capturedAt: capture.metadata.capturedAt,
            displayID: capture.metadata.displayID,
            applicationName: capture.metadata.frontmostApp?.name
        )
        present(item)
        ingest(item)
    }

    /// Shows a card for a finished recording (docs/03 §1.8).
    ///
    /// A recording is already a file on disk, so unlike a capture there is nothing to
    /// export first — the card points straight at it.
    func showRecording(at fileURL: URL) {
        Task { [weak self] in
            // Reading the track's size is asynchronous, so the card appears as soon as
            // the size is known rather than blocking the stop button on it.
            let size = await VideoPosterFrame.pixelSize(of: fileURL) ?? PixelSize(width: 0, height: 0)
            let item = QuickAccessItem(
                fileURL: fileURL,
                isStaged: false,
                pixelSize: size,
                capturedAt: Date(),
                displayID: nil,
                isVideo: true,
                historyKind: .video
            )
            self?.present(item)
            self?.ingestRecording(item)
        }
    }

    /// Shows a card for a stitched scrolling capture and opens it (docs/03 §1.6).
    ///
    /// Both, deliberately: doc 03 §1.6 says the output goes to the editor's scrolled
    /// canvas, and a card is how every other capture offers Save, Copy and drag. Opening
    /// the editor also finalises the staged file, so the page cannot be swept away from
    /// underneath the window showing it.
    func showScrollingCapture(at fileURL: URL, pixelSize: PixelSize) {
        let item = QuickAccessItem(
            fileURL: fileURL,
            isStaged: true,
            pixelSize: pixelSize,
            capturedAt: Date(),
            displayID: nil,
            historyKind: .scrolling
        )
        present(item)
        ingest(item)
        if editor.isAvailable {
            annotate(item)
        }
    }

    /// Brings back the most recently dismissed card, or the latest history item (docs/03 §2, §5).
    func restoreRecentlyClosed() {
        if let item = recentlyClosed.first {
            recentlyClosed.removeFirst()
            // Its file may have been deleted in the meantime.
            guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
                logger.info("The most recently closed capture is gone; nothing to restore")
                restoreRecentlyClosed()
                return
            }
            present(item)
            return
        }
        Task { [weak self] in
            guard let self, let record = await history?.mostRecent() else { return }
            presentFromHistory(record)
        }
    }

    /// Re-opens a library item as a Quick Access card (docs/03 §5).
    func presentFromHistory(_ record: HistoryRecord) {
        guard let store = history?.store else { return }
        let url = store.fileURL(for: record)
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("History item \(record.originalFilename, privacy: .public) is gone")
            return
        }
        history?.markAccessed(record)

        // A project is a document, not a capture card: reopening one means picking up
        // the editing session where it was left (docs/03 §3 P3, docs/06 M24).
        guard !record.kind.opensInEditor else {
            editor.open(url)
            return
        }

        present(QuickAccessItem(
            fileURL: url,
            isStaged: false,
            pixelSize: record.pixelSize,
            capturedAt: record.capturedAt,
            displayID: nil,
            isVideo: record.kind == .video,
            historyKind: record.kind,
            displayName: record.originalFilename,
            applicationName: record.applicationName
        ))
    }

    /// Dismisses every card without deleting anything.
    func dismissAll() {
        for entry in panels {
            recordClosed(entry.item)
            entry.panel.dismiss()
        }
        panels.removeAll()
        dismissTasks.values.forEach { $0.cancel() }
        dismissTasks.removeAll()
    }

    // MARK: - Presenting

    func present(_ item: QuickAccessItem) {
        let panel = QuickAccessPanel(item: item, settings: settings, actions: actions(for: item))
        panels.insert((item, panel), at: 0)
        panel.present(at: .zero)
        restack()
        scheduleAutoDismiss(for: item)
        logger.info("Quick Access card shown for \(item.filename, privacy: .public)")
    }

    /// Positions every card in the configured corner, newest in front.
    ///
    /// Positions come off `visibleFrame`, not `frame`, which is what keeps cards clear of
    /// the Dock and the menu bar (docs/03 §2 accept list).
    func restack() {
        guard let screen = targetScreen() else { return }
        let area = screen.visibleFrame
        let maxVisible = settings.overlayMaxVisibleCards

        for (index, entry) in panels.enumerated() {
            let size = entry.panel.frame.size
            // Collapsed cards peek out from behind the front one rather than stacking
            // off the screen forever.
            let step = index < maxVisible ? Self.cardSpacing + size.height : Self.cardSpacing
            let offset = index < maxVisible
                ? CGFloat(index) * step
                : CGFloat(maxVisible) * (Self.cardSpacing + size.height) + CGFloat(index - maxVisible) * 6

            let x = settings.overlayCorner.isLeading
                ? area.minX + Self.screenMargin
                : area.maxX - size.width - Self.screenMargin
            let y = settings.overlayCorner.isBottom
                ? area.minY + Self.screenMargin + offset
                : area.maxY - size.height - Self.screenMargin - offset

            entry.panel.setStackDepth(index, origin: CGPoint(x: x, y: y))
            // Beyond the visible count the card is a hint that more exist, not a card.
            entry.panel.alphaValue = index < maxVisible ? entry.panel.alphaValue : 0.25
        }
    }

    func targetScreen() -> NSScreen? {
        if settings.overlayOnPrimaryDisplay {
            return NSScreen.screens.first
        }
        // The display the capture came from, falling back to the one with the pointer.
        let captureDisplay = panels.first?.item.displayID
        let matching = captureDisplay.flatMap { displayID in
            NSScreen.screens.first { ScreenDescriptor($0)?.displayID == displayID }
        }
        return matching ?? NSScreen.main ?? NSScreen.screens.first
    }

    func scheduleAutoDismiss(for item: QuickAccessItem) {
        let seconds = settings.overlayTimeout.seconds
        guard seconds > 0 else { return }
        dismissTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss(item)
        }
    }

    func copyFile(at url: URL, isVideo: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !isVideo else {
            pasteboard.writeObjects([url as NSURL])
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func save(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        dismiss(item)
    }

    /// Dragging a card out counts as acting on it, so a staged file becomes a real one
    /// and the card goes if the user asked for that (docs/03 §2).
    /// The receiver asked for the file: finalise it and hand back where it now lives.
    ///
    /// Reading the URL back out of `panels` rather than trusting the captured item is the
    /// whole fix for docs/07 C1 — `finalizeIfStaged` *moves* the file, and the card view's
    /// copy of the item still holds the path it had before the move.
    func resolveForDrag(_ item: QuickAccessItem) -> URL? {
        finalizeIfStaged(item)
        let url = panels.first { $0.item.id == item.id }?.item.fileURL ?? item.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("Dragged capture is gone: \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        return url
    }

    /// The drag finished. Only a drop that a receiver accepted may dismiss the card —
    /// dismissing at drag start loses the capture when the user changes their mind
    /// (docs/09 U0.1).
    func dragCompleted(_ item: QuickAccessItem, accepted: Bool) {
        guard accepted, settings.overlayDismissOnDrag else { return }
        dismiss(item)
    }

    /// The first thing a user does with a staged capture finalises it (docs/03 §2).
    func finalizeIfStaged(_ item: QuickAccessItem) {
        guard item.isStaged, let index = panels.firstIndex(where: { $0.item.id == item.id }) else { return }
        guard let moved = output.finalizeStaged(item.fileURL) else { return }
        panels[index].item.fileURL = moved
        panels[index].item.isStaged = false
    }

    /// Dismiss ≠ delete: the file stays where the policy put it (docs/03 §2).
    func dismiss(_ item: QuickAccessItem) {
        guard let index = panels.firstIndex(where: { $0.item.id == item.id }) else { return }
        let entry = panels.remove(at: index)
        dismissTasks.removeValue(forKey: item.id)?.cancel()
        recordClosed(entry.item)
        entry.panel.dismiss()
        restack()
    }

    /// Deletes the capture as well as the card.
    func delete(_ item: QuickAccessItem) {
        guard let index = panels.firstIndex(where: { $0.item.id == item.id }) else { return }
        let entry = panels.remove(at: index)
        dismissTasks.removeValue(forKey: item.id)?.cancel()
        entry.panel.dismiss()
        // The library keeps its own content-addressed copy, so trashing the file alone
        // left a "deleted" capture sitting in App Support until retention expired — which
        // for a sensitive screenshot is the whole problem (docs/07 H5). Hashed before the
        // trash, because afterwards there is nothing to hash.
        history?.deleteFromLibrary(matching: entry.item.fileURL)
        // Deleted means gone, so it is not offered for restore.
        try? FileManager.default.trashItem(at: entry.item.fileURL, resultingItemURL: nil)
        logger.info("Deleted \(entry.item.filename, privacy: .public)")
        restack()
    }

    func recordClosed(_ item: QuickAccessItem) {
        recentlyClosed.insert(item, at: 0)
        if recentlyClosed.count > Self.maximumRecentlyClosed {
            recentlyClosed.removeLast()
        }
    }

    func ingest(_ item: QuickAccessItem, thumbnailSourceURL: URL? = nil) {
        history?.ingest(HistoryIngest(
            sourceURL: item.fileURL,
            kind: item.historyKind,
            pixelSize: item.pixelSize,
            applicationName: item.applicationName,
            capturedAt: item.capturedAt,
            originalFilename: item.filename,
            thumbnailSourceURL: thumbnailSourceURL,
            // A poster is rendered for the ingest and belongs to it; the library deletes
            // it once its own copy is written (docs/07 LOW).
            thumbnailSourceIsTemporary: thumbnailSourceURL != nil
        ))
    }

    /// Recordings need a still ImageIO can thumbnail; the poster is that still.
    func ingestRecording(_ item: QuickAccessItem) {
        Task { [weak self] in
            guard let self else { return }
            let poster = await writePoster(for: item.fileURL)
            ingest(item, thumbnailSourceURL: poster)
        }
    }

    func writePoster(for video: URL) async -> URL? {
        guard let image = await VideoPosterFrame.posterFrame(
            of: video,
            maxPixelSize: HistoryThumbnailWriter.maxPixelSize
        ) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-poster-\(UUID().uuidString).jpg")
        do {
            try HistoryThumbnailWriter.write(image, to: url)
            return url
        } catch {
            logger.error("Could not write a recording poster: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
