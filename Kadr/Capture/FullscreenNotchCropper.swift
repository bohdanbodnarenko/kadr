import AppKit
import CaptureCore
import CoreGraphics
import OverlayKit
import SettingsKit
import Shared

/// Applies the capture-pane notch crop using the live display's safe area.
enum FullscreenNotchCropper {
    static func apply(_ capture: Capture, settings: AppSettings) -> Capture {
        guard settings.cropNotchFromFullscreen else { return capture }
        guard let displayID = capture.metadata.displayID else { return capture }
        guard let screen = NSScreen.screens.first(where: {
            ScreenDescriptor($0)?.displayID == displayID
        }) else {
            return capture
        }
        let inset = screen.safeAreaInsets.top
        guard inset > 0 else { return capture }
        return NotchCrop.apply(
            capture,
            enabled: true,
            topInsetPoints: inset,
            displayFrame: DisplayRect(cgRect: CGDisplayBounds(displayID))
        )
    }
}
