import AppKit
import CaptureCore
import MediaExport
import os
import OverlayKit
import SettingsKit
import Shared

/// Owns the Quick Access Overlay: the cards, where they sit, and when they go away.
///
/// This is the surface doc 03 §2 calls the product, so its rules are worth stating:
/// cards never take focus, they stack with the newest in front, they sit inside the
/// screen's visible frame so they never cover the Dock, and dismissing a card is not
/// the same as deleting its file.
@MainActor
final class QuickAccessManager {
    private let settings: AppSettings
    private let output: CaptureOutput
    private let pins: PinManager
    private let editor = EditorLauncher()
    /// The helper does the GIF encoding; the agent only asks for it (docs/04 §1).
    private let vision = VisionClient()
    private let logger = KadrLog.logger(.overlay)

    private var panels: [(item: QuickAccessItem, panel: QuickAccessPanel)] = []
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    /// Dismissed cards, newest first, for "Restore Recently Closed" (docs/03 §2).
    private var recentlyClosed: [QuickAccessItem] = []

    private static let cardSpacing: CGFloat = 12
    private static let screenMargin: CGFloat = 16
    private static let maximumRecentlyClosed = 10

    init(settings: AppSettings, output: CaptureOutput, pins: PinManager) {
        self.settings = settings
        self.output = output
        self.pins = pins
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
            displayID: capture.metadata.displayID
        )
        present(item)
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
            self?.present(QuickAccessItem(
                fileURL: fileURL,
                isStaged: false,
                pixelSize: size,
                capturedAt: Date(),
                displayID: nil,
                isVideo: true
            ))
        }
    }

    /// Brings back the most recently dismissed card (docs/03 §2).
    func restoreRecentlyClosed() {
        guard let item = recentlyClosed.first else { return }
        recentlyClosed.removeFirst()
        // Its file may have been deleted in the meantime.
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            logger.info("The most recently closed capture is gone; nothing to restore")
            return
        }
        present(item)
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

    private func present(_ item: QuickAccessItem) {
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
    private func restack() {
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

    private func targetScreen() -> NSScreen? {
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

    private func scheduleAutoDismiss(for item: QuickAccessItem) {
        let seconds = settings.overlayTimeout.seconds
        guard seconds > 0 else { return }
        dismissTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss(item)
        }
    }

    // MARK: - Card actions

    private func actions(for item: QuickAccessItem) -> QuickAccessCardActions {
        var actions = QuickAccessCardActions()
        actions.copy = { [weak self] in self?.copy(item) }
        actions.save = { [weak self] in self?.save(item) }
        actions.delete = { [weak self] in self?.delete(item) }
        actions.dismiss = { [weak self] in self?.dismiss(item) }
        actions.dragStarted = { [weak self] in self?.dragStarted(item) }
        actions.pin = { [weak self] in self?.pin(item) }
        actions.pinAvailable = true
        actions.annotate = { [weak self] in self?.annotate(item) }
        actions.annotateAvailable = editor.isAvailable
        actions.exportGIF = { [weak self] in self?.exportGIF(item) }
        return actions
    }

    /// Turns a recording into a GIF, asking first if it is going to be large (docs/03 §1.8).
    ///
    /// The encode happens in the helper process, so the agent never holds a single frame
    /// of it (docs/04 §1).
    private func exportGIF(_ item: QuickAccessItem) {
        let destination = item.fileURL.deletingPathExtension().appendingPathExtension("gif")
        Task { [weak self] in
            guard let self else { return }
            defer { vision.disconnect() }

            do {
                let estimate = try await vision.encodeGIF(GIFRequest(
                    sourcePath: item.fileURL.path,
                    destinationPath: destination.path,
                    estimateOnly: true
                ))
                guard confirmExport(estimatedBytes: estimate.byteCount) else { return }

                let result = try await vision.encodeGIF(GIFRequest(
                    sourcePath: item.fileURL.path,
                    destinationPath: destination.path
                ))
                guard let path = result.path else { return }
                logger.info("Exported \(URL(fileURLWithPath: path).lastPathComponent, privacy: .public)")
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } catch {
                logger.error("GIF export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Shows the estimate before committing, because a large GIF takes real time to make.
    private func confirmExport(estimatedBytes: Int) -> Bool {
        let size = ByteCountFormatter.string(fromByteCount: Int64(estimatedBytes), countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Export this recording as a GIF?"
        alert.informativeText = "The GIF will be roughly \(size). GIFs are much larger than "
            + "video, so long recordings get big quickly."
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func copy(_ item: QuickAccessItem) {
        guard let data = try? Data(contentsOf: item.fileURL) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        finalizeIfStaged(item)
    }

    /// Pinning counts as acting on a staged capture, so it is finalised first — a pin
    /// pointing at a file that the staging sweep later deletes would go blank.
    func pin(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        let url = panels.first { $0.item.id == item.id }?.item.fileURL ?? item.fileURL
        pins.pin(
            url,
            copy: { [weak self] fileURL in self?.copyFile(at: fileURL) },
            save: { [weak self] fileURL in self?.revealInFinder(fileURL) },
            annotate: { [weak self] fileURL in self?.editor.open(fileURL) }
        )
    }

    /// Opens the capture in the editor. Annotating counts as acting on a staged file, so
    /// it is finalised first — the editor must not be pointed at a file the staging sweep
    /// will delete underneath it.
    func annotate(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        let url = panels.first { $0.item.id == item.id }?.item.fileURL ?? item.fileURL
        editor.open(url)
    }

    private func copyFile(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func save(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        dismiss(item)
    }

    /// Dragging a card out counts as acting on it, so a staged file becomes a real one
    /// and the card goes if the user asked for that (docs/03 §2).
    private func dragStarted(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        if settings.overlayDismissOnDrag {
            dismiss(item)
        }
    }

    /// The first thing a user does with a staged capture finalises it (docs/03 §2).
    private func finalizeIfStaged(_ item: QuickAccessItem) {
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
        // Deleted means gone, so it is not offered for restore.
        try? FileManager.default.trashItem(at: entry.item.fileURL, resultingItemURL: nil)
        logger.info("Deleted \(entry.item.filename, privacy: .public)")
        restack()
    }

    private func recordClosed(_ item: QuickAccessItem) {
        recentlyClosed.insert(item, at: 0)
        if recentlyClosed.count > Self.maximumRecentlyClosed {
            recentlyClosed.removeLast()
        }
    }
}
