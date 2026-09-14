import AppKit
import EditorUI

extension EditorWindowController {
    /// Inserts this controller into the responder chain after the window is built.
    ///
    /// The window was built by hand rather than by an `NSWindowController`, so nothing
    /// linked this object to the chain — and the Edit menu's `undo:` therefore walked from
    /// the hosting view to the window and off the end.
    func installResponderChain() {
        guard let window else { return }
        nextResponder = window.nextResponder
        window.nextResponder = self
    }
}
