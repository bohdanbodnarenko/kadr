import AppKit

/// Returns keyboard focus to the control that presented a sheet or popover (docs/14 UX-02).
@MainActor
enum FocusRestoration {
    static func capture(from window: NSWindow?) -> NSResponder? {
        window?.firstResponder
    }

    static func restore(_ responder: NSResponder?, in window: NSWindow?) {
        guard let window else { return }
        window.makeFirstResponder(responder)
    }
}
