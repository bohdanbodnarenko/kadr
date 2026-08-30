import CoreGraphics
import Foundation

/// Turning a screen point into a moving window's own pixels (docs/09 U3.1).
///
/// A window recording is the one capture whose relationship to the screen changes while it
/// runs. A display and a region sit still, so where a click lands on screen fixes where it
/// lands in the frame once and for all; a window can be dragged and resized, and the same
/// screen point means something different afterwards.
///
/// Two corrections, and the second is the one that is easy to miss. Dragging shifts the
/// origin, which is a subtraction. *Resizing* does not change the recording's pixel size at
/// all — ScreenCaptureKit fixes that when the stream starts and scales the window into it —
/// so a window made twice as wide has its content squeezed to half scale, and a conversion
/// using the scale it started with puts every later click at twice the distance from the
/// left edge that it should be.
///
/// Which is why this is proportional rather than scaled: a point a third of the way across
/// the window is a third of the way across the frame, whatever the window's size has done
/// since.
public enum WindowSpace {
    /// The recording's pixel size, from the window's size when the stream started.
    ///
    /// Fixed for the whole recording, because that is how SCK behaves: the output
    /// dimensions are chosen once and everything afterwards is fitted into them.
    public static func pixelSize(ofFirst contentRect: CGRect, scale: CGFloat) -> CGSize {
        CGSize(
            width: max(contentRect.width * scale, 1),
            height: max(contentRect.height * scale, 1)
        )
    }

    /// Where a screen point falls in the recorded frame, or nil if it falls outside it.
    ///
    /// - Parameters:
    ///   - contentRect: where the window is on screen *now*, from SCK's per-frame attachment.
    ///   - pixelSize: the recording's fixed pixel size.
    public static func framePoint(
        for screenPoint: CGPoint,
        contentRect: CGRect,
        pixelSize: CGSize
    ) -> CGPoint? {
        guard contentRect.width > 0, contentRect.height > 0 else { return nil }
        guard contentRect.contains(screenPoint) else { return nil }
        return CGPoint(
            x: (screenPoint.x - contentRect.minX) / contentRect.width * pixelSize.width,
            y: (screenPoint.y - contentRect.minY) / contentRect.height * pixelSize.height
        )
    }
}
