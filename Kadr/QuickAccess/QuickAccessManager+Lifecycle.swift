import AppKit
import CaptureCore
import HistoryKit
import MediaExport
import os
import OverlayKit
import SettingsKit
import Shared
import SwiftUI

@MainActor
extension QuickAccessManager {
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
            dismissPeekingCards(pending, finalizeBeforeDismiss: finalizeBeforeDismiss)
            return
        }

        hoveredItemID = nil
        stopHoverKeyMonitor()

        dismissCascadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var failed = 0
            for item in pending {
                guard !Task.isCancelled else { return }
                guard items.contains(where: { $0.id == item.id }) else { continue }
                if finalizeBeforeDismiss, !finalizeIfStaged(item) {
                    failed += 1
                    continue
                }
                dismiss(item)
                guard !items.isEmpty else { break }
                try? await Task.sleep(for: Self.dismissCascadeInterval)
            }
            if failed > 0 {
                presentSaveFailureCount(failed)
            }
            areHidden = false
            dismissCascadeTask = nil
        }
    }

    private func dismissPeekingCards(_ pending: [QuickAccessItem], finalizeBeforeDismiss: Bool) {
        var failed = 0
        for item in pending where items.contains(where: { $0.id == item.id }) {
            if finalizeBeforeDismiss, !finalizeIfStaged(item) {
                failed += 1
                continue
            }
            dismiss(item)
        }
        areHidden = false
        if failed > 0 {
            presentSaveFailureCount(failed)
        }
    }

    func present(_ item: QuickAccessItem) {
        overlayExitTask?.cancel()
        isExiting = false
        // A new capture should be seen, even if the stack was tucked into the peek tab
        // or temporarily hidden for the next shot.
        if isPeeking {
            setPeeking(false)
        }
        if areHidden {
            setHidden(false)
        }
        let url = item.fileURL.standardizedFileURL
        if let index = items.firstIndex(where: { $0.fileURL.standardizedFileURL == url }) {
            var existing = items.remove(at: index)
            existing.pixelSize = item.pixelSize
            existing.isStaged = item.isStaged
            existing.contentRevision += 1
            items.insert(existing, at: 0)
            restack()
            scheduleAutoDismiss(for: existing)
            return
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
        stopHoverKeyMonitor()
        lastHoveredItemID = nil
        // A banner belongs to the stack it was shown over; a stale error must not come back
        // with the next capture (docs/17 T-OUT-2).
        feedbackStatus = nil
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
        return ActiveScreen.resolve(displayID: items.first?.displayID)
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
        var saved = 0
        for item in unsavedItems where finalizeIfStaged(item) {
            saved += 1
        }
        return saved
    }

    func copyFile(at url: URL, isVideo: Bool = false) {
        guard !isVideo else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let format = ImageFormat(fileExtension: url.pathExtension) ?? .png
        ClipboardWriter.shared.write(data: data, format: format, fileURL: url)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copies the file to a location the user picks, without moving the original (docs/16 OUT-8).
    func saveCopy(of url: URL) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = settings.saveFolder
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                self?.presentFeedback(.failure(error.localizedDescription))
            }
        }
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
        let live = items.first { $0.id == item.id } ?? item
        let url = live.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("Dragged capture is gone: \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        // A History card's file is named by its hash; the receiver gets the name the card
        // shows (docs/03 §2 "drag-out delivers a correctly named file", docs/17 T-OUT-10).
        if live.origin == .library, live.filename != url.lastPathComponent {
            return (try? LaunchScratch.current.link(url, named: Self.saveFilename(for: live))) ?? url
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
    /// Returns false when the file could not be moved, so the card stays (docs/16 OUT-3).
    @discardableResult
    func finalizeIfStaged(_ item: QuickAccessItem) -> Bool {
        guard item.isStaged, let index = items.firstIndex(where: { $0.id == item.id }) else { return true }
        let original = item.fileURL
        guard let moved = output.finalizeStaged(original) else { return false }
        CaptureProject.move(from: original, to: moved)
        items[index].fileURL = moved
        items[index].isStaged = false
        return true
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

    func forgetTransientState(for item: QuickAccessItem) {
        dismissTasks.removeValue(forKey: item.id)?.cancel()
        dismissDeadlines.removeValue(forKey: item.id)
        engagedItems.remove(item.id)
        if hoveredItemID == item.id {
            hoveredItemID = nil
            stopHoverKeyMonitorIfIdle()
        }
        if draggingItemID == item.id {
            draggingItemID = nil
        }
        if lastHoveredItemID == item.id {
            lastHoveredItemID = nil
        }
    }

    func finishRemoval() {
        if items.isEmpty {
            beginOverlayExit()
            return
        }
        restack()
    }

    /// Slides the last card or peek tab out, then tears the overlay down (docs/16 OUT-15).
    func beginOverlayExit() {
        isPeeking = false
        overlayExitTask?.cancel()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            teardownOverlay()
            isExiting = false
            return
        }
        isExiting = true
        overlayExitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(340))
            guard let self, !Task.isCancelled else { return }
            guard items.isEmpty else {
                isExiting = false
                return
            }
            teardownOverlay()
            isExiting = false
        }
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
