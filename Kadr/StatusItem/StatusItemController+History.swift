import AppKit
import HistoryKit

/// The status menu's recent-work group and its thumbnails (docs/03 §5, §8.1, docs/10 R2.4).
///
/// Split from the controller because the menu's history section is where its cost lives —
/// decoding and file-system work that must stay off the path between a click and the menu
/// appearing — and because the controller was over its length budget.
extension StatusItemController {
    /// Group 4 — the last few captures, and the window that holds the rest
    /// (docs/03 §5, §8.1).
    func addHistoryItems(to menu: NSMenu) {
        let recent = Array(history?.recent.prefix(HistoryController.menuStripCount) ?? [])
        menu.addItem(.separator())

        if !recent.isEmpty {
            let strip = HistoryStripView(frame: .zero)
            // Only what is already decoded goes in now; the rest arrives from
            // `fillThumbnails` a moment later. Decoding eight thumbnails here — and eight
            // more for the submenu — was up to sixteen ImageIO decodes on the main thread
            // between the click and the menu appearing.
            strip.update(records: recent) { [weak self] record in
                self?.cachedStripImage(for: record, size: HistoryStripView.thumbnailSize)
            }
            strip.onSelect = { [weak self] id in
                guard let record = self?.history?.record(id: id) else { return }
                self?.reopenFromHistory(record)
            }
            let item = NSMenuItem()
            item.view = strip
            menu.addItem(item)

            let recentMenu = NSMenu()
            var rows: [UUID: NSMenuItem] = [:]
            for record in recent {
                let row = NSMenuItem(
                    title: record.originalFilename,
                    action: #selector(didSelectRecent(_:)),
                    keyEquivalent: ""
                )
                row.target = self
                row.representedObject = record.id
                row.image = cachedStripImage(for: record, size: Self.recentRowImageSize)
                    ?? Self.recentRowPlaceholder
                recentMenu.addItem(row)
                rows[record.id] = row
            }
            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            recentItem.submenu = recentMenu
            menu.addItem(recentItem)
            fillThumbnails(for: recent, strip: strip, rows: rows)
        }

        let historyItem = NSMenuItem(title: "History…", action: #selector(didSelectHistory), keyEquivalent: "l")
        historyItem.keyEquivalentModifierMask = [.command, .shift]
        historyItem.target = self
        historyItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        menu.addItem(historyItem)

        let folderItem = NSMenuItem(
            title: "Open Capture Folder",
            action: #selector(didSelectOpenSaveFolder),
            keyEquivalent: ""
        )
        folderItem.target = self
        folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(folderItem)

        if canRestore() {
            let restoreItem = NSMenuItem(
                title: "Restore Recently Closed",
                action: #selector(didSelectRestore),
                keyEquivalent: "t"
            )
            restoreItem.keyEquivalentModifierMask = [.command, .shift]
            restoreItem.target = self
            menu.addItem(restoreItem)
        }

        addRecoveryItem(to: menu)
    }

    // MARK: - Thumbnails

    /// The one size the menu decodes. The 16 pt submenu rows reuse it, scaled by AppKit,
    /// rather than decoding a second, smaller copy of each capture.
    static let stripPixelSize = 112
    static let recentRowImageSize = NSSize(width: 16, height: 16)
    static let recentRowPlaceholder: NSImage? = {
        let image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        image?.size = recentRowImageSize
        return image
    }()

    private func cachedStripImage(for record: HistoryRecord, size: NSSize) -> NSImage? {
        guard let cgImage = history?.cachedThumbnail(
            for: record,
            maxPixelSize: Self.stripPixelSize,
            scope: .strip
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: size)
    }

    /// Decodes whatever the cache did not have, off the main thread, and drops each image
    /// into the open menu as it lands.
    private func fillThumbnails(for records: [HistoryRecord], strip: HistoryStripView, rows: [UUID: NSMenuItem]) {
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
                rows[record.id]?.image = NSImage(cgImage: cgImage, size: Self.recentRowImageSize)
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

    @objc
    func didSelectOpenSaveFolder() {
        perform(.openSaveFolder)
    }

    @objc
    func didSelectRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let record = history?.record(id: id)
        else {
            return
        }
        reopenFromHistory(record)
    }
}
