import AppKit
import KeyboardShortcuts

/// Overlay-stack and recovery items, split from the status item because the idle menu
/// grew past the file-length budget when CleanShot §6.3 actions landed.
extension StatusItemController {
    /// Commands over the surfaces a capture produces (docs/03 §2, §4).
    func addOverlayItems(to menu: NSMenu) {
        menu.addItem(.separator())

        let restoreItem = NSMenuItem(
            title: "Restore Recently Closed",
            action: #selector(didSelectRestore),
            keyEquivalent: "t"
        )
        restoreItem.keyEquivalentModifierMask = [.command, .shift]
        restoreItem.target = self
        restoreItem.isEnabled = canRestore()
        menu.addItem(restoreItem)

        let overlayCount = overlayCardCount()
        let overlaysHidden = overlaysAreHidden()
        for command in CaptureCommand.overlayCommands {
            let item = NSMenuItem(title: command.title, action: #selector(didSelectCapture(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.setShortcut(for: command.shortcutName)
            if command == .hideOverlays {
                item.title = overlaysHidden ? "Show Overlays" : "Hide Overlays"
                item.state = overlaysHidden ? .on : .off
            }
            item.isEnabled = overlayCount > 0
            menu.addItem(item)
        }

        let historyItem = NSMenuItem(
            title: "History…",
            action: #selector(didSelectHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        menu.addItem(historyItem)

        let closePinsItem = NSMenuItem(
            title: "Close All Pins",
            action: #selector(didSelectCloseAllPins),
            keyEquivalent: ""
        )
        closePinsItem.target = self
        closePinsItem.isEnabled = pinCount() > 0
        menu.addItem(closePinsItem)

        let hidePins = CaptureCommand.hidePins
        let hidePinsItem = NSMenuItem(
            title: pinsAreHidden() ? "Show Pins" : hidePins.title,
            action: #selector(didSelectCapture(_:)),
            keyEquivalent: ""
        )
        hidePinsItem.target = self
        hidePinsItem.representedObject = hidePins.rawValue
        hidePinsItem.setShortcut(for: hidePins.shortcutName)
        hidePinsItem.state = pinsAreHidden() ? .on : .off
        hidePinsItem.isEnabled = pinCount() > 0
        menu.addItem(hidePinsItem)

        addRecoveryItem(to: menu)
    }

    /// Offers to reopen recordings a crash left mid-edit (docs/09 U3.1).
    ///
    /// Absent rather than disabled when there are none, which is the opposite of the rule
    /// the rest of this menu follows — and deliberately so. A permanently visible "Recover"
    /// invites somebody to wonder what went wrong every time they open the menu, and the
    /// answer is almost always nothing. It appears when there is something to recover and
    /// disappears once there is not.
    func addRecoveryItem(to menu: NSMenu) {
        let count = unfinishedRecordings()
        guard count > 0 else { return }

        let title = count == 1
            ? "Recover Unfinished Recording…"
            : "Recover \(count) Unfinished Recordings…"
        let item = NSMenuItem(title: title, action: #selector(didSelectRecover), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc
    func didSelectRecover() {
        recoverRecordings()
    }
}
