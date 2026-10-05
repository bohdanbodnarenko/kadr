import AppKit
import os
import Shared

extension StatusItemController {
    func showIdleIcon() {
        showsRecordingIcon = false
        updateMenuBarVisibility()
        // A background-found update badges the icon; the menu's row was easy to miss
        // because a click opens the island, not the menu (docs/18 SH-3).
        let update = availableUpdate()
        apply(StatusItemAppearance(
            symbol: "camera.viewfinder",
            accessibilityDescription: update == nil ? "Kadr" : "Kadr — update available",
            isTemplate: true,
            title: "",
            length: NSStatusItem.squareLength,
            toolTip: update.map { String(localized: "Kadr — \($0) is available; right-click to update") }
                ?? "Kadr — click to capture, right-click for the menu",
            isBadged: update != nil
        ))
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
        apply(StatusItemAppearance(
            symbol: "viewfinder",
            accessibilityDescription: "Kadr — capture armed",
            isTemplate: true,
            title: "",
            length: NSStatusItem.squareLength,
            toolTip: "Kadr — capture armed"
        ))
        attachIdleMenu()
    }

    /// While recording: a red dot and the elapsed time, so the state is unmistakable from
    /// across the room (docs/03 §8.1).
    ///
    /// Deliberately *not* a template image — red is the point, and a template would be
    /// rendered monochrome like everything else in the menu bar.
    func showRecordingIcon(elapsed: String, isPaused: Bool) {
        showsRecordingIcon = true
        updateMenuBarVisibility()
        apply(StatusItemAppearance(
            symbol: isPaused ? "pause.circle.fill" : "record.circle",
            accessibilityDescription: "Recording",
            isTemplate: false,
            title: " \(elapsed)",
            length: NSStatusItem.variableLength,
            toolTip: "Click to stop · right-click for pause and discard"
        ))
        attachRecordingClick()
    }

    /// Puts an appearance on the button, touching only what differs (PRD §8).
    ///
    /// This runs whenever the recording clock or a capture surface changes. Rebuilding a
    /// palette symbol and re-assigning an identical image, title, length and tooltip each
    /// time made AppKit re-lay-out and redraw the status item for nothing; the symbol
    /// images are built once and kept, and an unchanged property is not assigned at all.
    func apply(_ appearance: StatusItemAppearance) {
        guard let button = statusItem.button else { return }
        if appliedIconKey != appearance.imageKey {
            button.image = icon(for: appearance)
            appliedIconKey = appearance.imageKey
        }
        if button.title != appearance.title {
            button.title = appearance.title
        }
        if !appearance.title.isEmpty, button.imagePosition != .imageLeading {
            button.imagePosition = .imageLeading
        }
        if statusItem.length != appearance.length {
            statusItem.length = appearance.length
        }
        if button.toolTip != appearance.toolTip {
            button.toolTip = appearance.toolTip
        }
    }

    private func icon(for appearance: StatusItemAppearance) -> NSImage? {
        if let cached = iconCache[appearance.imageKey] {
            return cached
        }
        var image = NSImage(
            systemSymbolName: appearance.symbol,
            accessibilityDescription: appearance.accessibilityDescription
        )
        if !appearance.isTemplate {
            image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        }
        if appearance.isBadged, let base = image {
            image = Self.badged(base)
        }
        image?.isTemplate = appearance.isTemplate
        if let image {
            iconCache[appearance.imageKey] = image
        }
        return image
    }

    /// `base` with a dot at its top-right corner, cut out of the glyph so it reads at menu
    /// bar size in either appearance. Drawn once and cached with the other icons.
    private static func badged(_ base: NSImage) -> NSImage {
        let size = base.size
        return NSImage(size: size, flipped: false) { rect in
            let diameter = max(4, size.width * 0.36)
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            base.draw(in: rect)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }

    /// Idle: a click opens the capture island; right-click, ⌃-click or ⌥-click opens the
    /// short menu (docs/03 §8.1).
    func attachIdleMenu() {
        attachClick(#selector(didClickIdleStatusItem))
    }

    /// Recording: a click stops, because that is the only thing the user is likely to want
    /// (docs/03 §1.8). Right-click still opens the menu for pause and discard.
    func attachRecordingClick() {
        attachClick(#selector(didClickStatusItem))
    }

    /// Routes clicks to `action`, skipping the work when they already go there — this is
    /// called on every clock change while recording.
    private func attachClick(_ action: Selector) {
        guard let button = statusItem.button else { return }
        guard statusItem.menu != nil || button.action != action || button.target !== self else { return }
        statusItem.menu = nil
        button.target = self
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// The island is the primary surface; the menu is for library, settings and quitting.
    ///
    /// The menu used to be the click target and carried every capture mode, utility and
    /// overlay command — twenty-odd rows before anything useful. Every one of those modes
    /// is a single key inside the island, so the island is what a click opens.
    @objc
    func didClickIdleStatusItem() {
        onIconClicked?()
        if Self.clickOpensMenu(NSApp.currentEvent) {
            popIdleMenu()
        } else {
            perform(.allInOne)
        }
    }

    /// Right-click, ⌃-click and ⌥-click all mean "the menu" — the three gestures macOS
    /// users try when a status item does something other than open one.
    static func clickOpensMenu(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        if event.type == .rightMouseUp {
            return true
        }
        return !event.modifierFlags.isDisjoint(with: [.control, .option])
    }

    /// VoiceOver and Full Keyboard Access press the button, which opens the island; the
    /// menu needs its own way in, or it is reachable only with a mouse.
    func installMenuAccessibilityAction() {
        guard let button = statusItem.button else { return }
        let action = NSAccessibilityCustomAction(name: "Show Kadr Menu") { [weak self] in
            self?.popIdleMenu()
            return true
        }
        button.setAccessibilityCustomActions([action])
        button.setAccessibilityHelp("Opens the capture island. Use the actions rotor for the menu.")
    }

    func popIdleMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        attachIdleMenu()
    }

    func applyMenuBarVisibility(_ visible: Bool) {
        userWantsMenuBarIcon = visible
        updateMenuBarVisibility()
    }

    /// What the item should show as: the user's choice, or forced on while recording.
    var desiredMenuBarVisibility: Bool {
        userWantsMenuBarIcon || showsRecordingIcon
    }

    private func updateMenuBarVisibility() {
        let desired = desiredMenuBarVisibility
        if statusItem.isVisible != desired {
            statusItem.isVisible = desired
        }
    }

    private static let menuBarVisibilityChanged = Notification.Name("app.kadr.menuBarVisibility")

    static func postMenuBarVisibility(_ visible: Bool) {
        NotificationCenter.default.post(name: menuBarVisibilityChanged, object: nil, userInfo: ["visible": visible])
    }

    /// Follows the menu-bar visibility setting and the user dragging the icon away.
    ///
    /// Idempotent, and the token is kept: this used to be called from both the initialiser
    /// and the app delegate, discarding the token each time, so every post reached two
    /// block observers that could never be removed.
    func observeMenuBarVisibility() {
        if menuBarVisibilityToken == nil {
            menuBarVisibilityToken = NotificationCenter.default.addObserver(
                forName: Self.menuBarVisibilityChanged,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let visible = (note.userInfo?["visible"] as? Bool) ?? true
                MainActor.assumeIsolated {
                    self?.statusItem.isVisible = visible
                }
            }
        }
        guard visibilityObservation == nil else { return }
        visibilityObservation = statusItem.observe(\.isVisible, options: [.new]) { [weak self] item, _ in
            let visible = item.isVisible
            Task { @MainActor in
                // Only the user's own drag counts. Kadr showing the item for a recording,
                // or applying the setting, must not write the setting back (docs/18 REC-2).
                guard let self, visible != self.desiredMenuBarVisibility else { return }
                self.onMenuBarVisibilityChange?(visible)
            }
        }
    }

    /// Removes both visibility observers. Called when the agent terminates.
    func stopObservingMenuBarVisibility() {
        if let menuBarVisibilityToken {
            NotificationCenter.default.removeObserver(menuBarVisibilityToken)
            self.menuBarVisibilityToken = nil
        }
        visibilityObservation?.invalidate()
        visibilityObservation = nil
    }
}

/// Everything the status item's button shows for one state.
struct StatusItemAppearance: Equatable {
    let symbol: String
    let accessibilityDescription: String
    let isTemplate: Bool
    let title: String
    let length: CGFloat
    let toolTip: String
    /// A dot on the glyph: something waits in the menu (docs/18 SH-3).
    var isBadged = false

    /// Two appearances with the same key share one image.
    var imageKey: String {
        "\(symbol)|\(isTemplate)|\(accessibilityDescription)|\(isBadged)"
    }
}
