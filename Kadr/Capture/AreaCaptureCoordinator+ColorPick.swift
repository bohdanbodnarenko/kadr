import AppKit
import os
import SelectionUI
import Shared

/// Reading a colour off the frozen screen (docs/03 §3 P3, docs/06 M22).
///
/// The eyedropper is a mode of the ordinary capture overlay rather than a surface of its
/// own, and deliberately so: it needs exactly what a capture needs — a frozen screen and a
/// loupe over it — and reusing them means the colour reported is the colour in the freeze,
/// not a re-sample of a screen that has moved on (docs/04 §4.2).
extension AreaCaptureCoordinator {
    /// Freezes the screen and opens the loupe as an eyedropper (docs/06 M22).
    ///
    /// The same freeze as any other capture, for the same reason: the colour reported is
    /// the colour in the frozen image, so it cannot drift from what the user is looking
    /// at while they line the loupe up (docs/04 §4.2).
    func beginColorPick() {
        startsInEyedropperMode = true
        beginOverlayCapture(mode: .area)
    }

    /// Puts a picked colour on the clipboard and says so (docs/06 M22).
    ///
    /// The clipboard, because a colour picked out of a screenshot is on its way into a
    /// stylesheet — and the same toast Capture Text uses, because the two are the same
    /// promise: something small was read off the screen and is now ready to paste.
    func deliver(_ pick: ColorPick) {
        let text = pick.clipboardText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logger.info("Picked \(pick.text, privacy: .public)")
        toast.show(text: text, codes: [], on: ActiveScreen.resolve())
        automation.report(.text(text))
    }
}
