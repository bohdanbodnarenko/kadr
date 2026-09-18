import AppKit
import KeyboardShortcuts

extension StatusItemController {
    /// Floating captures, in one submenu that exists only while there is something in it
    /// (docs/03 §2, §4).
    ///
    /// These were six top-level rows, most of them relevant only while a card or a pin is on
    /// screen. Pin Clipboard, which always applies, lives in the island's tools instead.
    func addOverlayItems(to menu: NSMenu) {
        let items = overlaySubmenuItems()
        guard !items.isEmpty else { return }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for item in items {
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: "Pins & Overlays", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        parent.submenu = submenu
        menu.addItem(parent)
    }

    func overlaySubmenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if overlayCardCount() > 0 {
            let hidden = overlaysAreHidden()
            items.append(makeCommandItem(.saveAllOverlays))
            items.append(makeCommandItem(.closeAllOverlays))
            let hide = makeCommandItem(.hideOverlays, title: hidden ? "Show Overlays" : "Hide Overlays")
            hide.state = hidden ? .on : .off
            items.append(hide)
        }
        if canRestore() {
            let restore = NSMenuItem(
                title: "Restore Recently Closed",
                action: #selector(didSelectRestore),
                keyEquivalent: ""
            )
            restore.target = self
            items.append(restore)
        }
        if pinCount() > 0 {
            if !items.isEmpty {
                items.append(.separator())
            }
            let hidden = pinsAreHidden()
            let hide = makeCommandItem(.hidePins, title: hidden ? "Show Pins" : CaptureCommand.hidePins.title)
            hide.state = hidden ? .on : .off
            items.append(hide)
            let close = NSMenuItem(title: "Close All Pins", action: #selector(didSelectCloseAllPins), keyEquivalent: "")
            close.target = self
            items.append(close)
        }
        return items
    }

    func addRecoveryItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "", action: #selector(didSelectRecover), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        recoveryItem = item
        updateRecoveryItem(count: unfinishedRecordings())
        refreshUnfinishedRecordings { [weak self] count in
            self?.updateRecoveryItem(count: count)
        }
    }

    func updateRecoveryItem(count: Int) {
        guard let recoveryItem else { return }
        recoveryItem.isHidden = count == 0
        recoveryItem.title = Self.recoveryTitle(count: count)
    }

    static func recoveryTitle(count: Int) -> String {
        count == 1
            ? "Recover Unfinished Recording…"
            : "Recover \(count) Unfinished Recordings…"
    }

    @objc
    func didSelectRecover() {
        recoverRecordings()
    }
}
