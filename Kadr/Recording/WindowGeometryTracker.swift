import CoreGraphics
import Foundation
import Shared
import StudioSession

/// Where the recorded content is on screen, as it changes (docs/09 U3.1).
///
/// A window recording's content moves when the window does, and every click recorded while
/// it moved has to be placed against where it was *then*. Which is why a window recording
/// could not keep a studio session before this existed: a click's position in the frame
/// cannot be derived from where it landed on screen without knowing what the frame was
/// showing at that instant, and a sidecar full of wrong positions is worse than none.
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

    /// Where the content was at an instant.
    ///
    /// The last sample at or before the time asked for, because a window is where it was
    /// put until it is moved again — interpolating between two positions would invent a
    /// glide across a jump the user made instantly.
    func frame(at time: TimeInterval) -> CGRect? {
        samples.last { $0.time <= time }?.frame ?? samples.first?.frame
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
    /// Fixed from the first frame, because SCK fixes the recording's dimensions then and
    /// scales everything afterwards into them. A window resized mid-recording keeps this
    /// size, which is exactly why the conversion has to be proportional.
    private var pixelSize: CGSize?

    /// Both come from the capture filter, together, so the scale is the one SCK actually
    /// rendered with rather than whatever `NSScreen` reports for the display the window is
    /// mostly on.
    func update(_ frame: CGRect, scale: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        self.frame = frame
        if pixelSize == nil {
            pixelSize = WindowSpace.pixelSize(ofFirst: frame, scale: scale)
        }
    }

    /// The converter to hand to the telemetry recorder.
    ///
    /// Returns nil for a point outside the window, which is how a click on something else
    /// stays out of the sidecar rather than being recorded at the nearest edge.
    func converter() -> @Sendable (CGPoint) -> CGPoint? {
        { [weak self] point in
            guard let self else { return nil }
            lock.lock()
            let frame = frame
            let pixelSize = pixelSize
            lock.unlock()

            // No geometry yet means the first frame has not arrived, so there is nowhere to
            // put the click. Dropping it is right: a click before the recording has a
            // picture is a click on nothing the recording shows.
            guard let frame, let pixelSize else { return nil }
            return WindowSpace.framePoint(for: point, contentRect: frame, pixelSize: pixelSize)
        }
    }
}
