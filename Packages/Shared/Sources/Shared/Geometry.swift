import CoreGraphics

// Coordinate and scale types for capture (docs/04 §5).
//
// macOS hands us three different coordinate systems and silently lets you mix them:
//
// * **Screen space** — AppKit's `NSScreen.frame`, origin at the *bottom-left* of the
//   primary display, measured in points.
// * **Display space** — CoreGraphics' and ScreenCaptureKit's `SCDisplay.frame`, origin
//   at the *top-left* of the primary display, measured in points.
// * **Pixels** — a display's backing store, top-left origin, scaled by its backing
//   scale factor. This is what a captured `CGImage` is measured in.
//
// Mixing them produces upside-down or half-size screenshots — the two most common bugs
// in this category of app. These types make each system a distinct Swift type so the
// mistakes stop compiling, and every conversion goes through one tested function.

// MARK: - Scale

/// A display's backing scale factor: 1 on a non-Retina display, 2 on a Retina one.
public struct DisplayScale: Hashable, Sendable {
    public let factor: CGFloat

    public init(_ factor: CGFloat) {
        precondition(factor > 0, "A display scale must be positive, got \(factor)")
        self.factor = factor
    }

    public static let oneToOne = DisplayScale(1)
    public static let retina = DisplayScale(2)
}

// MARK: - Screen space (AppKit, bottom-left origin, points)

/// A point in AppKit's global screen space: origin bottom-left, unit points.
public struct ScreenPoint: Hashable, Sendable, Codable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

/// A rect in AppKit's global screen space: origin bottom-left, unit points.
///
/// `origin` is the **bottom-left** corner, matching `NSRect`.
public struct ScreenRect: Hashable, Sendable, Codable {
    public var origin: ScreenPoint
    public var width: CGFloat
    public var height: CGFloat

    public init(origin: ScreenPoint, width: CGFloat, height: CGFloat) {
        self.origin = origin
        self.width = width
        self.height = height
    }

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.init(origin: ScreenPoint(x: x, y: y), width: width, height: height)
    }

    /// Interprets an `NSRect`-style value, which uses exactly this convention.
    public init(cgRect: CGRect) {
        self.init(x: cgRect.origin.x, y: cgRect.origin.y, width: cgRect.width, height: cgRect.height)
    }

    public var cgRect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    public var minX: CGFloat {
        origin.x
    }

    public var maxX: CGFloat {
        origin.x + width
    }

    /// The bottom edge, which in this space is the *smaller* y.
    public var minY: CGFloat {
        origin.y
    }

    public var maxY: CGFloat {
        origin.y + height
    }

    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    public func contains(_ point: ScreenPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    /// A screen point in this rect's own points, origin top-left — where it lands in a
    /// flipped view that fills the rect. Nil outside it.
    public func topLeftLocalPoint(for point: ScreenPoint) -> CGPoint? {
        guard contains(point) else { return nil }
        return CGPoint(x: point.x - minX, y: maxY - point.y)
    }

    /// A screen point in this rect's own backing pixels, origin top-left.
    ///
    /// Clicks arrive in AppKit space (origin bottom-left). Captured frames are pixels
    /// with a top-left origin. This is the one conversion both the display recorder and
    /// the region recorder must use — doing the Y-flip ad-hoc is how a halo lands on
    /// the wrong edge (docs/10 R3.5).
    public func pixelPoint(for point: ScreenPoint, scale: DisplayScale) -> PixelPoint? {
        guard contains(point) else { return nil }
        return PixelPoint(
            x: (point.x - minX) * scale.factor,
            y: (maxY - point.y) * scale.factor
        )
    }
}

// MARK: - Display space (CoreGraphics / ScreenCaptureKit, top-left origin, points)

/// A point in CoreGraphics' global display space: origin top-left, unit points.
public struct DisplayPoint: Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

/// A rect in CoreGraphics' global display space: origin top-left, unit points.
///
/// `origin` is the **top-left** corner, matching `CGDisplayBounds` and `SCDisplay.frame`.
public struct DisplayRect: Hashable, Sendable {
    public var origin: DisplayPoint
    public var width: CGFloat
    public var height: CGFloat

    public init(origin: DisplayPoint, width: CGFloat, height: CGFloat) {
        self.origin = origin
        self.width = width
        self.height = height
    }

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.init(origin: DisplayPoint(x: x, y: y), width: width, height: height)
    }

    /// Interprets a `CGDisplayBounds` / `SCDisplay.frame` value.
    public init(cgRect: CGRect) {
        self.init(x: cgRect.origin.x, y: cgRect.origin.y, width: cgRect.width, height: cgRect.height)
    }

    public var cgRect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    public var minX: CGFloat {
        origin.x
    }

    public var maxX: CGFloat {
        origin.x + width
    }

    /// The top edge, which in this space is the *smaller* y.
    public var minY: CGFloat {
        origin.y
    }

    public var maxY: CGFloat {
        origin.y + height
    }

    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    public func contains(_ other: DisplayRect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    public func intersects(_ other: DisplayRect) -> Bool {
        minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }
}

// MARK: - Pixels

/// A point in a capture's backing store: origin top-left, unit pixels.
///
/// Distinct from `ScreenPoint` so a Y-flip cannot compile away. Sub-pixel values are
/// allowed because a click is not required to land on a pixel centre.
public struct PixelPoint: Hashable, Sendable, Codable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// An integral size in a display's backing store.
public struct PixelSize: Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// An integral rect in a display's backing store: origin top-left, unit pixels.
public struct PixelRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var size: PixelSize {
        PixelSize(width: width, height: height)
    }

    public var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }
}

// MARK: - The global coordinate space

/// The one number that relates screen space to display space: the height of the
/// primary display, which both systems put their origin on opposite ends of.
public struct GlobalCoordinateSpace: Hashable, Sendable {
    public let primaryDisplayHeight: CGFloat

    public init(primaryDisplayHeight: CGFloat) {
        self.primaryDisplayHeight = primaryDisplayHeight
    }

    /// Reads the current primary display height from CoreGraphics.
    ///
    /// The main display is the one whose origin is `(0, 0)` in both systems, so its
    /// height is the flip axis regardless of how the other displays are arranged.
    public static var current: GlobalCoordinateSpace {
        GlobalCoordinateSpace(primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
    }
}

public extension DisplayPoint {
    /// Flips into AppKit's bottom-left origin space (docs/11 S0.1).
    ///
    /// The rect pair has had this conversion since M0; the *point* pair never did, so
    /// anything holding a single point had to flip it by hand or — as the event tap did —
    /// not at all. A `CGEvent`'s `location` is display space; `NSEvent.mouseLocation` is
    /// screen space; both are a bare `CGPoint`, and passing the first where the second was
    /// expected mirrors every sample vertically with no symptom until something draws it.
    func inScreenSpace(_ space: GlobalCoordinateSpace) -> ScreenPoint {
        ScreenPoint(x: x, y: space.primaryDisplayHeight - y)
    }
}

public extension ScreenPoint {
    /// Flips into CoreGraphics' top-left origin space.
    func inDisplaySpace(_ space: GlobalCoordinateSpace) -> DisplayPoint {
        DisplayPoint(x: x, y: space.primaryDisplayHeight - y)
    }
}

public extension ScreenRect {
    /// Flips into CoreGraphics' top-left origin space.
    func inDisplaySpace(_ space: GlobalCoordinateSpace) -> DisplayRect {
        DisplayRect(
            x: origin.x,
            y: space.primaryDisplayHeight - maxY,
            width: width,
            height: height
        )
    }
}

public extension DisplayRect {
    /// Flips into AppKit's bottom-left origin space.
    func inScreenSpace(_ space: GlobalCoordinateSpace) -> ScreenRect {
        ScreenRect(
            x: origin.x,
            y: space.primaryDisplayHeight - maxY,
            width: width,
            height: height
        )
    }
}

// MARK: - Displays

/// Everything needed to turn a global rect into a capture request for one display.
public struct DisplayGeometry: Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    /// The display's bounds in global display space (top-left origin, points).
    public let frame: DisplayRect
    public let scale: DisplayScale

    public init(displayID: CGDirectDisplayID, frame: DisplayRect, scale: DisplayScale) {
        self.displayID = displayID
        self.frame = frame
        self.scale = scale
    }

    /// The display's full backing-store size in pixels.
    public var pixelSize: PixelSize {
        PixelSize(
            width: Int((frame.width * scale.factor).rounded()),
            height: Int((frame.height * scale.factor).rounded())
        )
    }

    /// Rebases a global rect onto this display's own origin.
    ///
    /// ScreenCaptureKit's `sourceRect` is display-local, so every region capture has to
    /// make this move; doing it anywhere else is how regions land on the wrong monitor.
    public func localRect(for global: DisplayRect) -> DisplayRect {
        DisplayRect(
            x: global.minX - frame.minX,
            y: global.minY - frame.minY,
            width: global.width,
            height: global.height
        )
    }

    /// The inverse of `localRect(for:)`: a display-local rect, back in global display space.
    public func globalRect(for local: DisplayRect) -> DisplayRect {
        DisplayRect(
            x: local.minX + frame.minX,
            y: local.minY + frame.minY,
            width: local.width,
            height: local.height
        )
    }

    /// Converts a display-local point rect into backing-store pixels.
    ///
    /// Edges are rounded independently and the extent derived from them, so a rect that
    /// starts on a half-point never loses or gains a pixel of width.
    public func pixels(for local: DisplayRect) -> PixelRect {
        let minX = (local.minX * scale.factor).rounded()
        let minY = (local.minY * scale.factor).rounded()
        let maxX = (local.maxX * scale.factor).rounded()
        let maxY = (local.maxY * scale.factor).rounded()
        return PixelRect(
            x: Int(minX),
            y: Int(minY),
            width: Int(maxX - minX),
            height: Int(maxY - minY)
        )
    }

    /// Clamps a global rect to this display, returning `nil` when they do not overlap.
    ///
    /// Selections cannot span displays (docs/03 §1.1), so a rect that runs off the edge
    /// is trimmed rather than being captured from the wrong backing store.
    public func clamped(_ global: DisplayRect) -> DisplayRect? {
        guard frame.intersects(global) else { return nil }
        let minX = max(global.minX, frame.minX)
        let minY = max(global.minY, frame.minY)
        let maxX = min(global.maxX, frame.maxX)
        let maxY = min(global.maxY, frame.maxY)
        guard maxX > minX, maxY > minY else { return nil }
        return DisplayRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
