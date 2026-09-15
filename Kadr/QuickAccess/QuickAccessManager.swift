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
    /// Last card / peek tab is sliding out (docs/16 OUT-15).
    var isExiting = false
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
    /// Hears about captures the editor saved, so the card and History stay current.
    @ObservationIgnored var editorSaveObserver: (any NSObjectProtocol)?
    @ObservationIgnored var dismissTasks: [UUID: Task<Void, Never>] = [:]
    /// Cascades multi-card dismiss so each reflow animates (CleanShot §6.3 / 4.7.5).
    @ObservationIgnored var dismissCascadeTask: Task<Void, Never>?
    @ObservationIgnored var overlayExitTask: Task<Void, Never>?
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
    @ObservationIgnored var recentlyClosed: [QuickAccessItem] = []

    static let cardSpacing: CGFloat = 12
    static let screenMargin: CGFloat = 16
    /// Matches `QuickAccessStackView`'s reflow guard so each card finishes sliding before the next leaves.
    static let dismissCascadeInterval: Duration = .milliseconds(340)

    /// The stack's identity, for the animation that reflows it.
    var itemIDs: [UUID] {
        items.map(\.id)
    }

    static let maximumRecentlyClosed = 10

    init(settings: AppSettings, output: CaptureOutput, pins: PinManager, history: HistoryController? = nil) {
        self.settings = settings
        self.output = output
        self.pins = pins
        self.history = history
        watchForEditorDeletions()
        watchForEditorSaves()
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

    /// History ingest without a card, when "Show a card" is off (docs/16 OUT-1).
    func ingestWithoutCard(_ result: ExportResult, capture: Capture) {
        guard let fileURL = result.fileURL else { return }
        ingest(QuickAccessItem(
            fileURL: fileURL,
            isStaged: result.isStaged,
            pixelSize: capture.metadata.pixelSize,
            scale: capture.metadata.scale,
            capturedAt: capture.metadata.capturedAt,
            displayID: capture.metadata.displayID,
            applicationName: capture.metadata.frontmostApp?.name
        ))
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
            let actions = self?.settings.afterCaptureActions(for: .recording) ?? [.overlay]
            if actions.contains(.overlay) {
                self?.present(item)
            }
            self?.ingestRecording(item)
            if actions.contains(.copy) {
                self?.copyFile(at: fileURL, isVideo: true)
            }
            if actions.contains(.promptSave) {
                self?.promptSave(item)
            }
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
}
