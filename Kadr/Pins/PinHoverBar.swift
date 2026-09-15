import AppKit

/// Hover toolbar on a pin: Close, Copy, Save (docs/16 OUT-8).
@MainActor
final class PinHoverBar: NSVisualEffectView {
    private weak var panel: PinPanel?
    private let stack = NSStackView()
    private var copiedReset: Task<Void, Never>?
    private let copyButton = NSButton()

    init(panel: PinPanel) {
        self.panel = panel
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        stack.addArrangedSubview(iconButton(symbol: "xmark", action: #selector(closePin), help: "Close"))
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.bezelStyle = .regularSquare
        copyButton.isBordered = false
        copyButton.target = self
        copyButton.action = #selector(copyPin)
        copyButton.toolTip = "Copy"
        stack.addArrangedSubview(copyButton)
        stack.addArrangedSubview(iconButton(symbol: "square.and.arrow.down", action: #selector(savePin), help: "Save…"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let superview else { return }
        frame = CGRect(x: 8, y: superview.bounds.height - 36, width: 108, height: 28)
        autoresizingMask = [.minYMargin]
    }

    func setVisible(_ visible: Bool) {
        guard panel?.clickThroughEnabled != true else {
            isHidden = true
            return
        }
        isHidden = !visible
    }

    private func iconButton(symbol: String, action: Selector, help: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = help
        return button
    }

    @objc private func closePin() {
        panel?.onClose?()
    }

    @objc private func copyPin() {
        panel?.onCopy?()
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        copiedReset?.cancel()
        copiedReset = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        }
    }

    @objc private func savePin() {
        panel?.onSave?()
    }
}
