import AppKit

/// Returns keyboard focus to the control that presented a sheet (docs/14 UX-02).
@MainActor
public enum FocusRestoration {
    public static func capture(from window: NSWindow?) -> NSResponder? {
        window?.firstResponder
    }

    public static func restore(_ responder: NSResponder?, in window: NSWindow?) {
        guard let window else { return }
        window.makeFirstResponder(responder)
    }
}
