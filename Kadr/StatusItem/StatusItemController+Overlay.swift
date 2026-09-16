import AppKit
import KeyboardShortcuts

/// Overlay-stack and recovery items, split from the status item because the idle menu
/// grew past the file-length budget when CleanShot §6.3 actions landed.
extension StatusItemController {
    /// Group 5 — commands over the surfaces a capture produced (docs/03 §2, §4).
    ///
    /// Absent when there is nothing on screen to act on. Pin Clipboard is the exception:
    /// it needs no card, only something on the clipboard, so it stands alone when the
    /// stack is empty (docs/14 UX-08).
    func addOverlayItems(to menu: NSMenu) {
        let overlayCount = overlayCardCount()
        let pins = pinCount()
        let overlaysHidden = overlaysAreHidden()
        let pinsHidden = pinsAreHidden()

        menu.addItem(.separator())

        for command in CaptureCommand.overlayCommands {
            if command == .pinClipboard {
                menu.addItem(makeCommandItem(command))
                continue
            }
            guard overlayCount > 0 else { continue }
            if command == .hideOverlays {
                let item = makeCommandItem(command, title: overlaysHidden ? "Show Overlays" : "Hide Overlays")
                item.state = overlaysHidden ? .on : .off
                menu.addItem(item)
            } else {
                menu.addItem(makeCommandItem(command))
            }
        }

        guard pins > 0 else { return }

        let hidePinsItem = makeCommandItem(
            .hidePins,
            title: pinsHidden ? "Show Pins" : CaptureCommand.hidePins.title
        )
        hidePinsItem.state = pinsHidden ? .on : .off
        menu.addItem(hidePinsItem)

        let closePinsItem = NSMenuItem(
            title: "Close All Pins",
            action: #selector(didSelectCloseAllPins),
            keyEquivalent: ""
        )
        closePinsItem.target = self
        menu.addItem(closePinsItem)
    }

    /// Offers to reopen recordings a crash left mid-edit (docs/09 U3.1).
    ///
    /// Absent rather than disabled when there are none, which is the opposite of the rule
    /// the rest of this menu follows — and deliberately so. A permanently visible "Recover"
    /// invites somebody to wonder what went wrong every time they open the menu, and the
    /// answer is almost always nothing. It appears when there is something to recover and
    /// disappears once there is not.
    ///
    /// The count shown is the cached one: listing and stat-ing every session folder on the
    /// main thread was part of what made the menu slow to open. The item is always added,
    /// hidden when there is nothing to recover, and a fresh count is taken off the main
    /// thread each time the menu opens — if it differs, the open menu is updated in place.
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
