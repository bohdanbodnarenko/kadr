import AppKit
import CaptureCore
import HistoryKit
import MediaExport
import Observation
import os
import OverlayKit
import SettingsKit
import Shared
import SwiftUI
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
@Observable
final class QuickAccessManager {
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let output: CaptureOutput
    @ObservationIgnored let pins: PinManager
    @ObservationIgnored var editor = EditorLauncher()
    /// The helper does the GIF encoding; the agent only asks for it (docs/04 §1).
    /// The helper connection for GIF encoding (docs/03 §1.8).
    @ObservationIgnored let vision = VisionClient()
    @ObservationIgnored let textRecognizer = TextRecognizer()
    /// Shows what OCR found, the same panel the selection overlay's text mode uses.
    @ObservationIgnored let textToast = TextCaptureToast()
    @ObservationIgnored let history: HistoryController?
    @ObservationIgnored let logger = KadrLog.logger(.overlay)

    /// The one-time tip over the first card, while it is up.
    @ObservationIgnored var coachTip: QuickAccessCoachTip?
    /// Space, over a card, to look at the capture full size.
    @ObservationIgnored lazy var quickLook = QuickLookPresenter { [weak self] peeking in
        self?.setPeeking(peeking)
    }

    /// The cards currently on screen, newest first.
    ///
    /// Observed, along with `isPeeking`: these two are what the stack draws, and the whole
    /// point of the single-panel overlay is that changing them animates rather than
    /// repositioning windows.
    var items: [QuickAccessItem] = []
    /// Whether the cards are collapsed to the peek tab (docs/03 §2).
    var isPeeking = false
    /// Anchored status for user-initiated work on a card (docs/14 UX-24).
    var feedbackStatus: FeedbackStatus?

    /// Whether the stack is ordered out so it does not appear in the next capture.
    @ObservationIgnored var areHidden = false
    @ObservationIgnored var overlayPanel: QuickAccessOverlayPanel?
    /// Cards the user opened in the editor (or studio / trim). Hover does not belong here.
    @ObservationIgnored var engagedItems: Set<UUID> = []
    /// Watches for the editor exiting, so the cards come back. Nil while not peeking.
    @ObservationIgnored var editorExitObserver: (any NSObjectProtocol)?
    /// Hears about captures the editor moved to the Trash, for the agent's whole life.
    @ObservationIgnored var editorDeletionObserver: (any NSObjectProtocol)?
    @ObservationIgnored var dismissTasks: [UUID: Task<Void, Never>] = [:]
    /// Cascades multi-card dismiss so each reflow animates (CleanShot §6.3 / 4.7.5).
    @ObservationIgnored private var dismissCascadeTask: Task<Void, Never>?
    /// The card the pointer is over. Hover pauses auto-dismiss; it does not claim the card.
    ///
    /// Not observed: the card tracks its own hover, so publishing this would redraw the
    /// whole stack every time the pointer crossed a card.
    @ObservationIgnored var hoveredItemID: UUID?
    /// The card currently being dragged out.
    @ObservationIgnored var draggingItemID: UUID?
    @ObservationIgnored var hoverKeyMonitor: Any?
    @ObservationIgnored var localKeyMonitor: Any?
    /// Dismissed cards, newest first, for "Restore recently closed" (docs/03 §2).
    @ObservationIgnored private var recentlyClosed: [QuickAccessItem] = []

    static let cardSpacing: CGFloat = 12
    static let screenMargin: CGFloat = 16
    /// Matches `QuickAccessStackView`'s reflow guard so each card finishes sliding before the next leaves.
    static let dismissCascadeInterval: Duration = .milliseconds(340)

    /// The stack's identity, for the animation that reflows it.
    var itemIDs: [UUID] {
        items.map(\.id)
    }

    private static let maximumRecentlyClosed = 10

    init(settings: AppSettings, output: CaptureOutput, pins: PinManager, history: HistoryController? = nil) {
        self.settings = settings
        self.output = output
        self.pins = pins
        self.history = history
        watchForEditorDeletions()
    }

    var hasRecentlyClosed: Bool {
        !recentlyClosed.isEmpty
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
            scale: capture.metadata.scale,
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
    /// export first — the card points straight at it. Dedicated GIF capture (`exportGIF`)
    /// encodes after stop and presents the GIF as well (CleanShot §13.6).
    func showRecording(at fileURL: URL, exportGIF: Bool = false) {
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
            if exportGIF {
                self?.exportGIF(item, confirm: false)
            }
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
        dismissCardsSequentially(Array(items), finalizeBeforeDismiss: false)
    }

    /// Removes several cards one at a time so the stack reflow animates instead of jumping.
    ///
    /// When the stack is tucked into the peek tab there is nothing to animate, so every
    /// card goes immediately. `saveAll()` passes `finalizeBeforeDismiss: true`.
    func dismissCardsSequentially(_ pending: [QuickAccessItem], finalizeBeforeDismiss: Bool) {
        dismissCascadeTask?.cancel()
        guard !pending.isEmpty else { return }

        if isPeeking {
            for item in pending where items.contains(where: { $0.id == item.id }) {
                if finalizeBeforeDismiss {
                    finalizeIfStaged(item)
                }
                dismiss(item)
            }
            areHidden = false
            return
        }

        hoveredItemID = nil
        stopHoverKeyMonitor()

        dismissCascadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for item in pending {
                guard !Task.isCancelled else { return }
                guard items.contains(where: { $0.id == item.id }) else { continue }
                if finalizeBeforeDismiss {
                    finalizeIfStaged(item)
                }
                dismiss(item)
                guard !items.isEmpty else { break }
                try? await Task.sleep(for: Self.dismissCascadeInterval)
            }
            areHidden = false
            dismissCascadeTask = nil
        }
    }

    func present(_ item: QuickAccessItem) {
        // A new capture should be seen, even if the stack was tucked into the peek tab
        // or temporarily hidden for the next shot.
        if isPeeking {
            setPeeking(false)
        }
        if areHidden {
            setHidden(false)
        }
        items.insert(item, at: 0)
        restack()
        scheduleAutoDismiss(for: item)
        presentCoachTipIfNeeded(for: item)
        logger.info("Quick Access card shown for \(item.filename, privacy: .public)")
    }

    /// Makes sure the stack has a panel, on the right screen.
    ///
    /// This is all that is left of what used to be a layout pass over every card. Positions
    /// come off `visibleFrame`, not `frame`, which is what keeps cards clear of the Dock and
    /// the menu bar (docs/03 §2 accept list) — the panel covers exactly that, and SwiftUI
    /// arranges the column inside it.
    func restack() {
        guard !areHidden, !items.isEmpty, let screen = targetScreen() else { return }
        overlayPanelIfNeeded().present(on: screen)
    }

    func overlayPanelIfNeeded() -> QuickAccessOverlayPanel {
        if let overlayPanel {
            return overlayPanel
        }
        let panel = QuickAccessOverlayPanel(content: EmptyView())
        // The content needs the panel, to hand back the frames that take clicks; the panel
        // needs the content. Set after construction rather than tangling the two.
        panel.setContent(QuickAccessStackView(manager: self) { [weak panel] rects in
            panel?.setInteractiveRects(rects)
        })
        panel.onScroll = { [weak self] deltaX, deltaY in
            self?.handleScroll(deltaX: deltaX, deltaY: deltaY)
        }
        overlayPanel = panel
        return panel
    }

    func teardownOverlay() {
        overlayPanel?.dismiss()
        overlayPanel = nil
    }

    /// A trackpad flick over a card: outward hides it, toward the screen edge tucks the
    /// stack into the peek tab (docs/03 §2).
    ///
    /// Acts on the hovered card, which is the one under the pointer that produced the
    /// scroll. When the overlay was one window per card this came for free — the card's own
    /// window got the event — so the wiring had to be rebuilt when they became one.
    func handleScroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard !isPeeking,
              let hoveredItemID,
              let item = items.first(where: { $0.id == hoveredItemID })
        else {
            return
        }
        switch OverlaySwipe.from(deltaX: deltaX, deltaY: deltaY, corner: settings.overlayCorner) {
        case .dismiss:
            dismiss(item)
        case .peek:
            setPeeking(true)
        case nil:
            break
        }
    }

    func targetScreen() -> NSScreen? {
        if settings.overlayOnPrimaryDisplay {
            return NSScreen.screens.first
        }
        // The display the capture came from, falling back to the one with the pointer.
        let captureDisplay = items.first?.displayID
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
        items.filter(\.isStaged)
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

    /// Dragging a card out counts as acting on it, so a staged file becomes a real one
    /// and the card goes if the user asked for that (docs/03 §2).
    /// The receiver asked for the file: finalise it and hand back where it now lives.
    ///
    /// Reading the URL back out of `items` rather than trusting the captured item is the
    /// whole fix for docs/07 C1 — `finalizeIfStaged` *moves* the file, and the card view's
    /// copy of the item still holds the path it had before the move.
    func resolveForDrag(_ item: QuickAccessItem) -> URL? {
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
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
        guard item.isStaged, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let original = item.fileURL
        guard let moved = output.finalizeStaged(original) else { return }
        CaptureProject.move(from: original, to: moved)
        items[index].fileURL = moved
        items[index].isStaged = false
    }

    /// Dismiss ≠ delete: the file stays where the policy put it (docs/03 §2).
    func dismiss(_ item: QuickAccessItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        dismissCoachTip(for: item)
        let removed = items.remove(at: index)
        forgetTransientState(for: item)
        recordClosed(removed)
        finishRemoval()
    }

    /// Deletes the capture as well as the card.
    func delete(_ item: QuickAccessItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        dismissCoachTip(for: item)
        let removed = items.remove(at: index)
        forgetTransientState(for: item)
        // The library keeps its own content-addressed copy, so trashing the file alone
        // left a "deleted" capture sitting in App Support until retention expired — which
        // for a sensitive screenshot is the whole problem (docs/07 H5). Hashed before the
        // trash, because afterwards there is nothing to hash.
        history?.deleteFromLibrary(matching: removed.fileURL)
        // Deleted means gone, so it is not offered for restore.
        CaptureProject.trash(alongside: removed.fileURL)
        try? FileManager.default.trashItem(at: removed.fileURL, resultingItemURL: nil)
        logger.info("Deleted \(removed.filename, privacy: .public)")
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
        if items.isEmpty {
            isPeeking = false
            stopWatchingForEditorExit()
            teardownOverlay()
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
}
