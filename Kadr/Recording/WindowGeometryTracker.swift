import CoreGraphics
import Foundation
import Shared
import StudioSession

/// Where the recorded content is on screen, as it changes (docs/09 U3.1).
///
/// Samples are written so a crash mid-recording still has a history, but conversion
/// happens live: `MovingWindowConverter` normalises each click as it arrives, using the
/// geometry in force, so the sidecar stores already-correct pixels (docs/10 R3.1).
///
/// Kept as a running latest-plus-history rather than a sample per frame. The rect is
/// reported only when it changes, so a window dragged twice produces two samples and a
/// window left alone produces one.
@MainActor
struct WindowGeometryTracker {
    private(set) var samples: [WindowGeometrySample] = []

    /// The most recent frame, for converting a click that is happening now.
    private(set) var current: CGRect?

    /// Notes a new position.
    mutating func record(_ frame: CGRect, at time: TimeInterval) {
        current = frame
        samples.append(WindowGeometrySample(time: max(time, 0), frame: frame))
    }

    mutating func reset() {
        samples = []
        current = nil
    }
}

/// Turns a screen point into a recorded frame's pixels while the frame moves.
///
/// A `@Sendable` closure is what the telemetry recorder wants, and the answer depends on
/// state that changes during the recording — so the state lives in a locked box the closure
/// captures, rather than being baked in when the recording starts the way a display's
/// converter can be.
final nonisolated class MovingWindowConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CGRect?
    /// The window's size when the stream started. Locked with `pixelSize`; hop 2 of the
    /// conversion needs both (docs/10 R3.1).
    private var originalSize: CGSize?
    /// Fixed from the first frame, because SCK fixes the recording's dimensions then and
    /// scales everything afterwards into them.
    private var pixelSize: CGSize?
    private var space = GlobalCoordinateSpace.current

    /// Both come from the capture filter, together, so the scale is the one SCK actually
    /// rendered with rather than whatever `NSScreen` reports for the display the window is
    /// mostly on.
    func update(_ frame: CGRect, scale: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        space = GlobalCoordinateSpace.current
        self.frame = frame
        if pixelSize == nil {
            originalSize = frame.size
            pixelSize = WindowSpace.pixelSize(ofFirst: frame, scale: scale)
        }
    }

    /// The converter to hand to the telemetry recorder.
    ///
    /// Returns nil for a point outside the window, which is how a click on something else
    /// stays out of the sidecar rather than being recorded at the nearest edge.
    func converter() -> @Sendable (ScreenPoint) -> PixelPoint? {
        { [weak self] point in
            guard let self else { return nil }
            lock.lock()
            let frame = frame
            let pixelSize = pixelSize
            let originalSize = originalSize
            let space = space
            lock.unlock()

            // No geometry yet means the first frame has not arrived, so there is nowhere to
            // put the click. Dropping it is right: a click before the recording has a
            // picture is a click on nothing the recording shows.
            guard let frame, let pixelSize else { return nil }
            // SCK's content rect is display space, origin top-left; the point arrives in
            // screen space, origin bottom-left. Converting once, by name, is exactly what
            // C1 cost us for leaving implicit (docs/11 S0.1).
            let display = point.inDisplaySpace(space)
            return WindowSpace.framePoint(
                for: CGPoint(x: display.x, y: display.y),
                contentRect: frame,
                pixelSize: pixelSize,
                originalSize: originalSize
            ).map { PixelPoint(x: $0.x, y: $0.y) }
        }
    }
}
