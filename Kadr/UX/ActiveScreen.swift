import AppKit
import OverlayKit
import Shared

/// Which screen UI should land on (docs/16 X-5).
///
/// Explicit display ID, then the screen containing the pointer, then main. Countdowns,
/// cards, pins and the recording bar all go through here so a capture on a sidecar
/// display never opens chrome on the laptop.
enum ActiveScreen {
    static func resolve(displayID: CGDirectDisplayID? = nil, screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        if let displayID, let match = screens.first(where: { ScreenDescriptor($0)?.displayID == displayID }) {
            return match
        }
        let pointer = ScreenPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
        if let underPointer = screens.first(where: { $0.frame.contains(CGPoint(x: pointer.x, y: pointer.y)) }) {
            return underPointer
        }
        return NSScreen.main ?? screens.first
    }
}
