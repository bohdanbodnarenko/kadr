import CoreGraphics
import Foundation
import Shared

/// Which surface a capture came from.
public enum CaptureSource: Sendable, Hashable {
    case display(CGDirectDisplayID)
    case region(display: CGDirectDisplayID)
    case window(CGWindowID)
    /// Chosen through `SCContentSharingPicker`, which never tells us what was picked.
    case picker
}

/// The app that was in front when the capture was taken.
///
/// Sampled at hotkey time rather than at capture time: by the time the selection
/// overlay is up, the frontmost app is Kadr, which is useless in a filename.
public struct AppIdentity: Sendable, Hashable {
    public let name: String?
    public let bundleIdentifier: String?

    public init(name: String?, bundleIdentifier: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Everything about a capture except its pixels.
///
/// This is what the filename template, the history index and the editor all read, so it
/// carries the source geometry rather than just the bitmap size.
public struct CaptureMetadata: Sendable, Hashable {
    public let source: CaptureSource
    /// The display the pixels came from, when there is exactly one.
    public let displayID: CGDirectDisplayID?
    public let scale: DisplayScale
    /// The captured area in global display space (top-left origin, points).
    public let pointRect: DisplayRect
    /// The size of the returned image, in pixels.
    public let pixelSize: PixelSize
    public let colorSpaceName: String?
    public let frontmostApp: AppIdentity?
    public let windowTitle: String?
    public let capturedAt: Date

    public init(
        source: CaptureSource,
        displayID: CGDirectDisplayID?,
        scale: DisplayScale,
        pointRect: DisplayRect,
        pixelSize: PixelSize,
        colorSpaceName: String?,
        frontmostApp: AppIdentity?,
        windowTitle: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.source = source
        self.displayID = displayID
        self.scale = scale
        self.pointRect = pointRect
        self.pixelSize = pixelSize
        self.colorSpaceName = colorSpaceName
        self.frontmostApp = frontmostApp
        self.windowTitle = windowTitle
        self.capturedAt = capturedAt
    }
}

/// A still capture: pixels plus provenance.
public struct Capture: Sendable {
    public let image: CGImage
    public let metadata: CaptureMetadata

    public init(image: CGImage, metadata: CaptureMetadata) {
        self.image = image
        self.metadata = metadata
    }
}

/// One display's frozen contents (docs/04 §4.2).
///
/// The selection overlay crops out of this image rather than re-capturing, which is what
/// makes the result WYSIWYG even when a video is playing underneath.
public struct DisplayFreeze: Sendable {
    public let geometry: DisplayGeometry
    public let image: CGImage
    public let capturedAt: Date

    public init(geometry: DisplayGeometry, image: CGImage, capturedAt: Date = Date()) {
        self.geometry = geometry
        self.image = image
        self.capturedAt = capturedAt
    }
}

/// A window as ScreenCaptureKit sees it, flattened into a value type.
///
/// `SCWindow` is a reference type that is not `Sendable`, so it never leaves the capture
/// actor; this crosses instead.
public struct WindowInfo: Sendable, Hashable, Identifiable {
    public let id: CGWindowID
    public let title: String?
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let processID: pid_t
    /// The window's frame in global display space (top-left origin, points).
    public let frame: DisplayRect
    public let isOnScreen: Bool
    public let layer: Int

    public init(
        id: CGWindowID,
        title: String?,
        applicationName: String?,
        bundleIdentifier: String?,
        processID: pid_t,
        frame: DisplayRect,
        isOnScreen: Bool,
        layer: Int
    ) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.layer = layer
    }

    /// Whether this is a window a user would think of as a window — excludes the
    /// desktop, the menu bar and other system layers.
    public var isUserWindow: Bool {
        layer == 0 && frame.width >= 40 && frame.height >= 40
    }
}

/// A `Sendable` snapshot of `SCShareableContent`.
public struct ShareableContentSnapshot: Sendable {
    public let displays: [DisplayGeometry]
    public let windows: [WindowInfo]
    public let capturedAt: Date

    public init(displays: [DisplayGeometry], windows: [WindowInfo], capturedAt: Date = Date()) {
        self.displays = displays
        self.windows = windows
        self.capturedAt = capturedAt
    }

    public func display(_ id: CGDirectDisplayID) -> DisplayGeometry? {
        displays.first { $0.displayID == id }
    }

    /// The display a rect belongs to: the one it overlaps most.
    ///
    /// Selections cannot span displays (docs/03 §1.1), so "most overlap" is the rule for
    /// deciding which backing store a stray rect should be read from.
    public func display(containing rect: DisplayRect) -> DisplayGeometry? {
        displays
            .compactMap { geometry -> (DisplayGeometry, CGFloat)? in
                guard let clamped = geometry.clamped(rect) else { return nil }
                return (geometry, clamped.width * clamped.height)
            }
            .max { $0.1 < $1.1 }?
            .0
    }
}

/// Options for a window capture (docs/03 §1.2).
public struct WindowCaptureOptions: Sendable, Hashable {
    /// Include the window's drop shadow.
    public var includesShadow: Bool
    /// Keep the window's own alpha instead of compositing onto an opaque background,
    /// so rounded corners and vibrancy export as real transparency.
    public var transparentBackground: Bool
    public var includesCursor: Bool
    /// Include attached panels and sheets.
    public var includesChildWindows: Bool

    public init(
        includesShadow: Bool = true,
        transparentBackground: Bool = true,
        includesCursor: Bool = false,
        includesChildWindows: Bool = true
    ) {
        self.includesShadow = includesShadow
        self.transparentBackground = transparentBackground
        self.includesCursor = includesCursor
        self.includesChildWindows = includesChildWindows
    }
}

/// Options for the freeze that backs area selection (docs/03 §1.1).
public struct FreezeOptions: Sendable, Hashable {
    /// Leave Kadr's own overlay panels out, so re-freezing while the overlay is open
    /// does not photograph the overlay.
    public var excludesOwnWindows: Bool
    /// Leave the menu bar out.
    ///
    /// Off by default: the freeze is what the user is looking at, and a screenshot tool
    /// that cannot capture a menu is not much of one. Doc 03 §1.1 reads as excluding it;
    /// the exclusion is kept available here rather than imposed.
    public var excludesMenuBar: Bool
    public var includesCursor: Bool

    public init(excludesOwnWindows: Bool = true, excludesMenuBar: Bool = false, includesCursor: Bool = false) {
        self.excludesOwnWindows = excludesOwnWindows
        self.excludesMenuBar = excludesMenuBar
        self.includesCursor = includesCursor
    }
}
