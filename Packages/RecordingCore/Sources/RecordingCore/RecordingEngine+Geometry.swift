import CoreMedia
import Foundation
import ScreenCaptureKit

/// Where the recorded content is on screen, as it moves (docs/09 U3.1).
///
/// Split from the engine's own file because capturing frames and tracking where they came
/// from fail for different reasons and change for different reasons — and because the
/// engine was already at its length budget.
///
/// A display and a region never move, so this reports once and falls silent. A window moves
/// when somebody drags or resizes it, which is a handful of times in a recording rather than
/// sixty times a second.
extension RecordingEngine {
    /// Watches where the recorded content is on screen (docs/09 U3.1).
    ///
    /// Called only when the answer *changes*, with the recording time at which it did. A
    /// display recording never moves, and a window recording moves when somebody drags it —
    /// a handful of times in a session, not sixty times a second — so a per-frame
    /// attachment becomes a couple of dozen callbacks.
    /// - Parameter observer: the content's rect in screen points, the display scale that
    ///   turns those points into recorded pixels, and the recording time it changed at.
    ///   The scale comes from the capture filter rather than from `NSScreen`, because it is
    ///   what SCK actually rendered with — the two disagree on a window straddling displays
    ///   of different scales, and the filter is the one that made the pixels.
    public func setGeometryObserver(_ observer: (@Sendable (CGRect, CGFloat, TimeInterval) -> Void)?) {
        geometryObserver = observer
        lastContentRect = nil
    }

    /// Tells the observer when the content has moved.
    func reportGeometry(of box: SampleBufferBox, at time: TimeInterval) {
        guard let observer = geometryObserver, let rect = box.contentRect else { return }
        guard Self.hasMoved(from: lastContentRect, to: rect) else { return }
        lastContentRect = rect

        // Recording time, not wall-clock: a pause takes time out of the footage, and a
        // geometry sample stamped with the clock would point at a moment the file skips.
        observer(rect, pointPixelScale, time)
    }

    /// Whether a content rect has actually changed, as against jittering.
    ///
    /// SCK's rect wobbles by fractions of a point between otherwise identical frames, so
    /// comparing exactly would report a move on every frame — turning a design that costs
    /// a couple of dozen callbacks into one that costs one per frame.
    static func hasMoved(from previous: CGRect?, to rect: CGRect) -> Bool {
        guard let previous else { return true }
        return abs(previous.minX - rect.minX) >= geometryTolerance
            || abs(previous.minY - rect.minY) >= geometryTolerance
            || abs(previous.width - rect.width) >= geometryTolerance
            || abs(previous.height - rect.height) >= geometryTolerance
    }
}
