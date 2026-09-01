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

    /// The one-time tip over the first card, while it is up.
    var coachTip: QuickAccessCoachTip?

    var panels: [(item: QuickAccessItem, panel: QuickAccessPanel)] = []
    /// Cards the user opened in the editor (or studio / trim). Hover does not belong here.
    var engagedItems: Set<UUID> = []
    /// Whether the cards are collapsed to the peek tab (docs/03 §2).
    var isPeeking = false
    /// Watches for the editor exiting, so the cards come back. Nil while not peeking.
    var editorExitObserver: (any NSObjectProtocol)?
    var dismissTasks: [UUID: Task<Void, Never>] = [:]
    /// The card the pointer is over. Hover pauses auto-dismiss; it does not claim the card.
    var hoveredItemID: UUID?
    /// The card currently being dragged out.
    var draggingItemID: UUID?
    var peekPanel: QuickAccessPeekPanel?
    var hoverKeyMonitor: Any?
    var localKeyMonitor: Any?
    /// Dismissed cards, newest first, for "Restore recently closed" (docs/03 §2).
    private var recentlyClosed: [QuickAccessItem] = []

    static let cardSpacing: CGFloat = 12
    static let screenMargin: CGFloat = 16
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
        engagedItems.removeAll()
        hoveredItemID = nil
        draggingItemID = nil
        stopHoverKeyMonitor()
        isPeeking = false
        stopWatchingForEditorExit()
        teardownPeekTab()
    }

    // MARK: - Presenting

    func present(_ item: QuickAccessItem) {
        // A new capture should be seen, even if the stack was tucked into the peek tab.
        if isPeeking {
            setPeeking(false)
        }
        let panel = QuickAccessPanel(item: item, settings: settings, actions: actions(for: item))
        panels.insert((item, panel), at: 0)
        panel.present(at: .zero)
        restack()
        scheduleAutoDismiss(for: item)
        presentCoachTipIfNeeded(over: panel, item: item)
        logger.info("Quick Access card shown for \(item.filename, privacy: .public)")
    }

    /// Positions every card in the configured corner, newest in front.
    ///
    /// Positions come off `visibleFrame`, not `frame`, which is what keeps cards clear of
    /// the Dock and the menu bar (docs/03 §2 accept list).
    func restack() {
        guard let screen = targetScreen() else { return }
        if isPeeking {
            layoutPeekTab(on: screen)
            return
        }
        hidePeekTab()
        layoutCards(on: screen)
    }

    func layoutCards(on screen: NSScreen) {
        let area = screen.visibleFrame
        let maxVisible = settings.overlayMaxVisibleCards
        let cardWidth = CGFloat(settings.overlayCardWidth)
        for (index, entry) in panels.enumerated() {
            entry.panel.revealFromPeek()
            entry.panel.setCardSize(width: cardWidth, height: entry.panel.frame.height)
            let size = entry.panel.frame.size
            let origin = cardOrigin(index: index, size: size, area: area, maxVisible: maxVisible)
            entry.panel.setStackDepth(index, origin: origin)
            // Beyond the visible count the card is a hint that more exist, not a card.
            if index >= maxVisible {
                entry.panel.alphaValue = 0.25
            }
        }
    }

    func cardOrigin(index: Int, size: CGSize, area: CGRect, maxVisible: Int) -> CGPoint {
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
        return CGPoint(x: x, y: y)
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

    nonisolated static let editorBundleIdentifier = "app.kadr.Kadr.Editor"

    /// Captures a card's unsaved state for the quit prompt (docs/09 U2.1).
    ///
    /// A staged capture is one the user has not acted on: it lives in the staging area and
    /// the 24-hour sweep will delete it. Quitting with those on screen throws work away
    /// silently, which is the one thing a capture tool must not do.
    var unsavedItems: [QuickAccessItem] {
        panels.map(\.item).filter(\.isStaged)
    }

    var hasUnsavedItems: Bool {
        !unsavedItems.isEmpty
    }

    /// Finalises every staged capture, for the "Save All" answer to the quit prompt.
    @discardableResult
    func finalizeAllStaged() -> Int {
        let staged = unsavedItems
        for item in staged {
            finalizeIfStaged(item)
        }
        return staged.count
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
        endDrag(for: item)
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
        dismissCoachTip(for: item)
        let entry = panels.remove(at: index)
        forgetTransientState(for: item)
        recordClosed(entry.item)
        entry.panel.dismiss()
        finishRemoval()
    }

    /// Deletes the capture as well as the card.
    func delete(_ item: QuickAccessItem) {
        guard let index = panels.firstIndex(where: { $0.item.id == item.id }) else { return }
        dismissCoachTip(for: item)
        let entry = panels.remove(at: index)
        forgetTransientState(for: item)
        entry.panel.dismiss()
        // The library keeps its own content-addressed copy, so trashing the file alone
        // left a "deleted" capture sitting in App Support until retention expired — which
        // for a sensitive screenshot is the whole problem (docs/07 H5). Hashed before the
        // trash, because afterwards there is nothing to hash.
        history?.deleteFromLibrary(matching: entry.item.fileURL)
        // Deleted means gone, so it is not offered for restore.
        try? FileManager.default.trashItem(at: entry.item.fileURL, resultingItemURL: nil)
        logger.info("Deleted \(entry.item.filename, privacy: .public)")
        finishRemoval()
    }

    func forgetTransientState(for item: QuickAccessItem) {
        dismissTasks.removeValue(forKey: item.id)?.cancel()
        engagedItems.remove(item.id)
        if hoveredItemID == item.id {
            hoveredItemID = nil
            stopHoverKeyMonitorIfIdle()
        }
        if draggingItemID == item.id {
            draggingItemID = nil
        }
    }

    func finishRemoval() {
        if panels.isEmpty {
            isPeeking = false
            stopWatchingForEditorExit()
            teardownPeekTab()
            return
        }
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
