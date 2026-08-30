import CoreGraphics
import Foundation

/// Turning a screen point into a moving window's own pixels (docs/09 U3.1, docs/10 R3.1).
///
/// A window recording is the one capture whose relationship to the screen changes while it
/// runs. A display and a region sit still, so where a click lands on screen fixes where it
/// lands in the frame once and for all; a window can be dragged and resized, and the same
/// screen point means something different afterwards.
///
/// Two hops, and the second is the one that is easy to miss:
///
/// 1. Map the screen point through the window's `contentRect` *now*, as a 0…1 fraction.
/// 2. Place that fraction into the rectangle the window occupies *inside the fixed output
///    surface*. ScreenCaptureKit chooses the surface size when the stream starts and never
///    refits it. A shrink is scaled down and pinned to the surface's top-left; a grow is
///    scaled to fit. Stretching the fraction across the whole surface after a shrink puts
///    every later click too far from the origin — the bug Screendrop shipped a fix for
///    as "click positions in window recordings".
///
/// Normalised here, at capture time, so the sidecar stores already-correct pixels and no
/// consumer has to know windows move (docs/10 R3.1).
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

    /// Where the window's picture sits inside the fixed output, origin at the surface's
    /// top-left, size in pixels.
    ///
    /// `originalSize` is the window in points when the stream started. `currentSize` is
    /// it now. The ratio of the two, times the locked `pixelSize`, is how many pixels of
    /// the surface actually show the window — never more than the surface itself.
    public static func surfaceContentSize(
        currentSize: CGSize,
        originalSize: CGSize,
        pixelSize: CGSize
    ) -> CGSize {
        guard originalSize.width > 0, originalSize.height > 0 else { return pixelSize }
        return CGSize(
            width: min(currentSize.width / originalSize.width * pixelSize.width, pixelSize.width),
            height: min(currentSize.height / originalSize.height * pixelSize.height, pixelSize.height)
        )
    }

    /// Where a screen point falls in the recorded frame, or nil if it falls outside it.
    ///
    /// - Parameters:
    ///   - contentRect: where the window is on screen *now*, from SCK's per-frame attachment.
    ///   - pixelSize: the recording's fixed pixel size.
    ///   - originalSize: the window's size when the stream started, in the same space as
    ///     `contentRect`. Defaults to the current size, which is the identity hop.
    public static func framePoint(
        for screenPoint: CGPoint,
        contentRect: CGRect,
        pixelSize: CGSize,
        originalSize: CGSize? = nil
    ) -> CGPoint? {
        guard contentRect.width > 0, contentRect.height > 0 else { return nil }
        guard contentRect.contains(screenPoint) else { return nil }

        let nx = (screenPoint.x - contentRect.minX) / contentRect.width
        let ny = (screenPoint.y - contentRect.minY) / contentRect.height
        let surface = surfaceContentSize(
            currentSize: contentRect.size,
            originalSize: originalSize ?? contentRect.size,
            pixelSize: pixelSize
        )
        return CGPoint(x: nx * surface.width, y: ny * surface.height)
    }
}
