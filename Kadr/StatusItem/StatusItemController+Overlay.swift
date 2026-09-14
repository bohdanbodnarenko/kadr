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
