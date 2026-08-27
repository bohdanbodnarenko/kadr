import AppKit
import CoreGraphics
import Shared

/// One display, described as a value.
///
/// `NSScreen` is a reference type that AppKit recycles across reconfigurations, so
/// holding one across a display change is a bug waiting to happen. Overlay code works
/// from these snapshots instead, which also makes the per-screen bookkeeping testable
/// without a window server.
public struct ScreenDescriptor: Hashable, Sendable, Identifiable {
    public let displayID: CGDirectDisplayID
    /// The screen's frame in AppKit screen space (bottom-left origin, points).
    public let frame: ScreenRect
    public let backingScaleFactor: CGFloat

    public var id: CGDirectDisplayID {
        displayID
    }

    public init(displayID: CGDirectDisplayID, frame: ScreenRect, backingScaleFactor: CGFloat) {
        self.displayID = displayID
        self.frame = frame
        self.backingScaleFactor = backingScaleFactor
    }

    public var scale: DisplayScale {
        DisplayScale(backingScaleFactor)
    }
}

public extension ScreenDescriptor {
    /// Reads a descriptor off an `NSScreen`, or `nil` for a screen with no display ID —
    /// which happens briefly while displays are being reconfigured.
    init?(_ screen: NSScreen) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        self.init(
            displayID: CGDirectDisplayID(number.uint32Value),
            frame: ScreenRect(cgRect: screen.frame),
            backingScaleFactor: screen.backingScaleFactor
        )
    }
}

/// Supplies the current set of displays, behind a protocol so overlay bookkeeping can be
/// tested without attaching monitors.
@MainActor
public protocol ScreenProviding {
    func currentScreens() -> [ScreenDescriptor]
    /// The `NSScreen` matching a descriptor, when one is still attached.
    func screen(for descriptor: ScreenDescriptor) -> NSScreen?
}

/// The real thing: `NSScreen.screens`.
@MainActor
public struct SystemScreens: ScreenProviding {
    public init() {}

    public func currentScreens() -> [ScreenDescriptor] {
        NSScreen.screens.compactMap(ScreenDescriptor.init)
    }

    public func screen(for descriptor: ScreenDescriptor) -> NSScreen? {
        NSScreen.screens.first { ScreenDescriptor($0)?.displayID == descriptor.displayID }
    }
}
