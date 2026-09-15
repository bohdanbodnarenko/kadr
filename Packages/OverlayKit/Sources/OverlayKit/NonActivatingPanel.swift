import AppKit
import Shared

/// The overlay panel recipe from docs/04 §5, in one place.
///
/// Every full-screen surface Kadr puts up — selection, freeze, HUD — needs the same
/// unusual combination:
///
/// * **Borderless and non-activating**, so putting it on screen does not steal focus
///   from whatever the user was doing. That matters: the frontmost app is what the
///   capture gets named after, and a capture that changes the answer is useless.
/// * **`canBecomeKey` overridden to true**, because a non-activating panel refuses key
///   status by default and then Esc, arrows and typing do nothing. This one line is the
///   difference between a working overlay and a mysteriously dead one.
/// * **`.screenSaver` level** to sit above full-screen apps and the Dock.
/// * **All Spaces, full-screen auxiliary, stationary**, so the overlay follows the user
///   rather than triggering a Space switch.
open class NonActivatingPanel: NSPanel {
    /// Selection, countdown and the scroll HUD stay out of captures even when the user
    /// opts in (docs/16 X-6).
    public var alwaysHiddenFromCaptures = false
    /// Without this the panel never becomes key and every keyboard interaction dies.
    override open var canBecomeKey: Bool {
        true
    }

    /// Deliberately false: the overlay must never take main-window status from the app
    /// the user is looking at.
    override open var canBecomeMain: Bool {
        false
    }

    public convenience init(contentRect: NSRect, level: NSWindow.Level = .screenSaver) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureAsOverlay(level: level)
    }

    /// Applies the shared overlay configuration.
    public func configureAsOverlay(level: NSWindow.Level = .screenSaver) {
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        // ARC owns the panel; letting AppKit release it on close is a use-after-free.
        isReleasedWhenClosed = false
        // Overlays are transient and must not restore themselves on relaunch.
        isRestorable = false
        animationBehavior = .none
        // Full-screen overlays have nothing to do with the Window menu.
        isExcludedFromWindowsMenu = true
        // Invisible to ScreenCaptureKit and to `screencapture`, so a freeze that
        // captures a display rect (without an excludingWindows filter) does not
        // photograph the overlay that is sitting on top of it (docs/10 R3.2).
        sharingType = CaptureVisibility.sharingType(alwaysExcluded: alwaysHiddenFromCaptures)
    }

    /// Registers for capture exclusion the moment the overlay is on screen (docs/10 R3.2).
    ///
    /// Overlays that also register themselves explicitly are harmless: the registry
    /// deduplicates. Unregistering on `orderOut`/`close` is what keeps a dismissed
    /// overlay from occupying a slot after it is gone.
    override open func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        CaptureExclusionRegistry.shared.register(self)
    }

    override open func orderFrontRegardless() {
        super.orderFrontRegardless()
        CaptureExclusionRegistry.shared.register(self)
    }

    override open func orderOut(_ sender: Any?) {
        CaptureExclusionRegistry.shared.unregister(self)
        super.orderOut(sender)
    }

    override open func close() {
        CaptureExclusionRegistry.shared.unregister(self)
        super.close()
    }
}

/// A panel that can be shown on one screen and torn down again.
///
/// `PerScreenWindowSet` is written against this rather than `NSPanel` so the per-screen
/// bookkeeping — hot-plug, teardown, ordering — can be unit tested without a display.
@MainActor
public protocol OverlayWindowing: AnyObject {
    func present(on screen: ScreenDescriptor)
    func dismiss()
}
