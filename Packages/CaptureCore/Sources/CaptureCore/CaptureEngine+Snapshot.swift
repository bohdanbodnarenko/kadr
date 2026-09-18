import CoreGraphics
import ScreenCaptureKit
import Shared

/// Shareable content as value types, windows front to back (docs/03 §1.2).
extension CaptureEngine {
    func snapshot(of content: SCShareableContent) -> ShareableContentSnapshot {
        let displays = content.displays.map { display in
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return DisplayGeometry(
                displayID: display.displayID,
                frame: DisplayRect(cgRect: display.frame),
                scale: DisplayScale(CGFloat(filter.pointPixelScale))
            )
        }
        let windows = content.windows.map { window in
            WindowInfo(
                id: window.windowID,
                title: window.title,
                applicationName: window.owningApplication?.applicationName,
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                processID: window.owningApplication?.processID ?? 0,
                frame: DisplayRect(cgRect: window.frame),
                isOnScreen: window.isOnScreen,
                layer: window.windowLayer
            )
        }
        // Front to back, as hit-testing needs them (`WindowStackOrder`).
        let stacked = WindowStackOrder.ordered(
            windows,
            stack: WindowStackOrder.current(),
            excluding: excludedWindowIDs
        )
        return ShareableContentSnapshot(displays: displays, windows: stacked)
    }
}
