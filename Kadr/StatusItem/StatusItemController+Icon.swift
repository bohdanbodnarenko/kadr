import AppKit
import os
import Shared

extension StatusItemController {
    func showIdleIcon() {
        showsRecordingIcon = false
        let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kadr")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.title = ""
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.toolTip = "Kadr"
        attachIdleMenu()
    }

    /// Capture armed: a selection overlay, a self-timer badge, or the recorder's picker is
    /// on screen (docs/03 §8.1, docs/14 UX-08A).
    ///
    /// A different template glyph rather than a colour or a pulse: the menu bar is
    /// monochrome by convention, and this state lasts as long as somebody takes to choose
    /// a region — a repeating animation there is a repeating animation in the process
    /// whose whole design is that it has none.
    func showArmedIcon() {
        showsRecordingIcon = false
        let icon = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Kadr — capture armed")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.title = ""
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.toolTip = "Kadr — capture armed"
        attachIdleMenu()
    }

    /// While recording: a red dot and the elapsed time, so the state is unmistakable from
    /// across the room (docs/03 §8.1).
    ///
    /// Deliberately *not* a template image — red is the point, and a template would be
    /// rendered monochrome like everything else in the menu bar.
    func showRecordingIcon(elapsed: String, isPaused: Bool) {
        showsRecordingIcon = true
        let name = isPaused ? "pause.circle.fill" : "record.circle"
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let icon = NSImage(systemSymbolName: name, accessibilityDescription: "Recording")?
            .withSymbolConfiguration(configuration)
        icon?.isTemplate = false

        statusItem.button?.image = icon
        statusItem.button?.title = " \(elapsed)"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.toolTip = "Click to stop · right-click for pause and discard"
        attachRecordingClick()
    }

    /// Idle: Option-click opens All-in-One; otherwise the menu opens (docs/03 §8.1).
    func attachIdleMenu() {
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(didClickIdleStatusItem)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Recording: a click stops, because that is the only thing the user is likely to want
    /// (docs/03 §1.8). Right-click still opens the menu for pause and discard.
    func attachRecordingClick() {
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(didClickStatusItem)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc
    func didClickIdleStatusItem() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            popIdleMenu()
            return
        }
        if event?.modifierFlags.contains(.option) == true {
            perform(.allInOne)
            return
        }
        popIdleMenu()
    }

    func popIdleMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        attachIdleMenu()
    }

    func applyMenuBarVisibility(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    private static let menuBarVisibilityChanged = Notification.Name("app.kadr.menuBarVisibility")

    static func postMenuBarVisibility(_ visible: Bool) {
        NotificationCenter.default.post(name: menuBarVisibilityChanged, object: nil, userInfo: ["visible": visible])
    }

    func observeMenuBarVisibility() {
        NotificationCenter.default.addObserver(
            forName: Self.menuBarVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let visible = (note.userInfo?["visible"] as? Bool) ?? true
            MainActor.assumeIsolated {
                self?.statusItem.isVisible = visible
            }
        }
        visibilityObservation = statusItem.observe(\.isVisible, options: [.new]) { [weak self] item, _ in
            let visible = item.isVisible
            Task { @MainActor in
                self?.onMenuBarVisibilityChange?(visible)
            }
        }
    }
}
