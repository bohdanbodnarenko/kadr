import AppKit

extension PinContentView {
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let panel else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let copy = NSMenuItem(title: "Copy", action: #selector(copyPin), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        let save = NSMenuItem(title: "Save…", action: #selector(savePin), keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealPin), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let annotate = NSMenuItem(title: "Annotate", action: #selector(annotatePin), keyEquivalent: "")
        annotate.target = self
        menu.addItem(annotate)

        let ocr = NSMenuItem(title: "Copy Text", action: #selector(copyPinText), keyEquivalent: "")
        ocr.target = self
        menu.addItem(ocr)

        menu.addItem(.separator())

        // Opacity from the menu too (docs/03 §4), so it never depends on a scroll gesture.
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let levels = NSMenu()
        for percent in Self.opacityLevels {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setPinOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = Int((panel.alphaValue * 100).rounded()) == percent ? .on : .off
            levels.addItem(item)
        }
        opacity.submenu = levels
        menu.addItem(opacity)

        let clickThrough = NSMenuItem(
            title: panel.clickThroughEnabled ? "Stop Click-Through" : "Click-Through",
            action: #selector(toggleClickThrough),
            keyEquivalent: "l"
        )
        clickThrough.keyEquivalentModifierMask = [.command, .option]
        clickThrough.target = self
        menu.addItem(clickThrough)

        menu.addItem(.separator())

        let close = NSMenuItem(title: "Close Pin", action: #selector(closePin), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)

        return menu
    }

    @objc func annotatePin() {
        panel?.onAnnotate?()
    }

    @objc func copyPinText() {
        panel?.onCopyText?()
    }

    @objc func copyPin() {
        panel?.onCopy?()
    }

    @objc func savePin() {
        panel?.onSave?()
    }

    @objc func revealPin() {
        panel?.onReveal?()
    }

    @objc func closePin() {
        panel?.onClose?()
    }

    @objc func toggleClickThrough() {
        panel?.toggleClickThrough()
    }

    static let opacityLevels = [100, 75, 50, 25]

    @objc func setPinOpacity(_ sender: NSMenuItem) {
        panel?.setOpacity(CGFloat(sender.tag) / 100)
    }
}
