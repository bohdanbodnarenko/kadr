import AppKit
import HistoryKit
import KeyboardShortcuts

/// The status menu's recent-work group and its thumbnails (docs/03 §5, §8.1, docs/10 R2.4).
///
/// Split from the controller because the menu's history section is where its cost lives —
/// decoding and file-system work that must stay off the path between a click and the menu
/// appearing — and because the controller was over its length budget.
extension StatusItemController {
    /// Group 4 — the last few captures, and the window that holds the rest
    /// (docs/03 §5, §8.1).
    /// Recent work: the thumbnail strip, History, and anything a crash left unfinished.
    ///
    /// The strip is the list. A "Recent" submenu used to repeat the same eight captures by
    /// file name underneath it; the strip's buttons carry the same names for VoiceOver, so
    /// the second copy was only length.
    func addHistoryItems(to menu: NSMenu) {
        let recent = Array(history?.recent.prefix(HistoryController.menuStripCount) ?? [])
        Self.addGroupSeparator(to: menu)

        if !recent.isEmpty {
            let strip = HistoryStripView(frame: .zero)
            // Only what is already decoded goes in now; the rest arrives from
            // `fillThumbnails` a moment later, so opening the menu never waits on ImageIO.
            strip.update(records: recent) { [weak self] record in
                self?.cachedStripImage(for: record)
            }
            strip.onSelect = { [weak self] id in
                guard let record = self?.history?.record(id: id) else { return }
                self?.reopenFromHistory(record)
            }
            let item = NSMenuItem()
            item.view = strip
            menu.addItem(item)
            fillThumbnails(for: recent, strip: strip)
        }

        // The global shortcut, if the user gave History one — not a hard-coded ⇧⌘L that
        // only worked while this menu happened to be open.
        let historyItem = NSMenuItem(
            title: String(localized: "History…"),
            action: #selector(didSelectHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        historyItem.setShortcut(for: CaptureCommand.openHistory.shortcutName)
        historyItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        menu.addItem(historyItem)

        addRecoveryItem(to: menu)
    }

    // MARK: - Thumbnails

    /// The one size the menu decodes.
    static let stripPixelSize = 112

    private func cachedStripImage(for record: HistoryRecord) -> NSImage? {
        guard let cgImage = history?.cachedThumbnail(
            for: record,
            maxPixelSize: Self.stripPixelSize,
            scope: .strip
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: HistoryStripView.thumbnailSize)
    }

    /// Decodes whatever the cache did not have, off the main thread, and drops each image
    /// into the open menu as it lands.
    private func fillThumbnails(for records: [HistoryRecord], strip: HistoryStripView) {
        thumbnailFillTask?.cancel()
        guard let history else { return }
        let missing = records.filter {
            history.cachedThumbnail(for: $0, maxPixelSize: Self.stripPixelSize, scope: .strip) == nil
        }
        guard !missing.isEmpty else { return }
        thumbnailFillTask = Task { [weak strip] in
            for record in missing {
                guard !Task.isCancelled else { return }
                guard let cgImage = await history.loadThumbnail(
                    for: record,
                    maxPixelSize: Self.stripPixelSize,
                    scope: .strip
                ) else {
                    continue
                }
                guard !Task.isCancelled else { return }
                strip?.setThumbnail(
                    NSImage(cgImage: cgImage, size: HistoryStripView.thumbnailSize),
                    for: record.id
                )
            }
        }
    }

    // MARK: - Actions

    @objc
    func didSelectRestore() {
        restoreRecentlyClosed()
    }

    @objc
    func didSelectHistory() {
        openHistory()
    }
}
