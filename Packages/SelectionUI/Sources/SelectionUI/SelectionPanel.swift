import AppKit
import OverlayKit
import Shared

/// A borderless overlay panel carrying one display's selection surface.
@MainActor
final class SelectionPanel: NonActivatingPanel, OverlayWindowing {
    private let overlayView: SelectionOverlayView
    /// Which display this panel covers, so results that arrive later find the right one.
    let displayID: CGDirectDisplayID

    init(
        frozen: FrozenDisplay,
        screen: ScreenDescriptor,
        mode: SelectionOverlayView.Mode,
        purpose: SelectionPurpose
    ) {
        let frame = screen.frame.cgRect
        displayID = frozen.geometry.displayID
        overlayView = SelectionOverlayView(
            frozenImage: frozen.image,
            bounds: CGRect(origin: .zero, size: frame.size),
            scale: frozen.geometry.scale,
            mode: mode,
            purpose: purpose
        )
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureAsOverlay()
        alwaysHiddenFromCaptures = true
        contentView = overlayView
    }

    var view: SelectionOverlayView {
        overlayView
    }

    func present(on screen: ScreenDescriptor) {
        setFrame(screen.frame.cgRect, display: true)
        orderFrontRegardless()
        // Not made key here: with several displays the last panel created would win. The
        // controller makes the pointer's display key once every panel is up (T-CAP-2).
    }

    /// Takes the keyboard for this display.
    func takeKeyboard() {
        makeKey()
        makeFirstResponder(overlayView)
    }

    func dismiss() {
        // Drop the frozen bitmap with the view — it is the overlay's whole memory cost.
        contentView = nil
        orderOut(nil)
        close()
    }
}
