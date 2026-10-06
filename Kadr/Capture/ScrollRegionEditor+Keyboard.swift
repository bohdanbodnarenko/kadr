import AppKit
import Carbon.HIToolbox

/// The frame without a pointer (docs/18 CAP-12).
///
/// ⌥-arrows move it and ⌥⇧-arrows resize it from the bottom-right corner, 10 pt a press.
/// Modified rather than bare arrows: the keys are hot keys while the editor is up, and
/// plain arrows are how the user scrolls the page they are lining up.
@MainActor
extension ScrollRegionEditor {
    static let keyboardStep: CGFloat = 10

    func arrowBindings() -> [TransientHotKeys.Key: @MainActor () -> Void] {
        var bindings: [TransientHotKeys.Key: @MainActor () -> Void] = [:]
        let arrows: [(UInt32, CGVector)] = [
            (UInt32(kVK_LeftArrow), CGVector(dx: -Self.keyboardStep, dy: 0)),
            (UInt32(kVK_RightArrow), CGVector(dx: Self.keyboardStep, dy: 0)),
            (UInt32(kVK_UpArrow), CGVector(dx: 0, dy: Self.keyboardStep)),
            (UInt32(kVK_DownArrow), CGVector(dx: 0, dy: -Self.keyboardStep))
        ]
        for (keyCode, delta) in arrows {
            let move = TransientHotKeys.Key(keyCode: keyCode, carbonModifiers: UInt32(optionKey))
            let resize = TransientHotKeys.Key(keyCode: keyCode, carbonModifiers: UInt32(optionKey | shiftKey))
            bindings[move] = { [weak self] in self?.regionView?.nudge(by: delta, resizing: false) }
            bindings[resize] = { [weak self] in self?.regionView?.nudge(by: delta, resizing: true) }
        }
        return bindings
    }

    private var regionView: ScrollRegionView? {
        panel?.contentView as? ScrollRegionView
    }
}

extension ScrollRegionView {
    /// Moves or resizes the frame by `delta`, kept inside the display and above the
    /// minimum size, exactly as a drag would.
    func nudge(by delta: CGVector, resizing: Bool) {
        guard !isLocked else { return }
        let target: ScrollRegionGeometry.Target = resizing ? .resize(.right, .bottom) : .move
        setRect(ScrollRegionGeometry.dragged(rect, target: target, by: delta, in: limits).integral)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    override func accessibilityLabel() -> String? {
        String(localized: "Scrolling capture frame")
    }

    override func accessibilityValue() -> Any? {
        String(localized: "\(Int(rect.width)) by \(Int(rect.height)) points")
    }

    override func accessibilityHelp() -> String? {
        String(localized: "Option-arrow keys move the frame. Option-Shift-arrow keys resize it. Return starts.")
    }
}
