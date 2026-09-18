import CoreGraphics
import Foundation

/// Where a zoom points, drawn on the picture itself (docs/09 U3.3).
///
/// A cue stores an anchor and a magnification, which says *what it looks at* but shows
/// nothing: the timeline says when a zoom happens and the inspector's pad is a map of
/// somewhere else. This turns the pair into the rectangle the export will actually fill the
/// frame with, in the preview's own coordinates, and turns a drag on that picture back into
/// an anchor.
///
/// Pure, because the interesting part is the clamping: a zoom aimed at a corner cannot
/// centre on that corner without showing the outside of the recording, so the camera stops
/// with its edge against the picture's edge — and a target drawn anywhere else would be a
/// promise the render does not keep.
enum StudioZoomTargetGeometry {
    /// A zoom never goes below 1× (the whole picture) and the inspector's slider caps it.
    static let magnificationLimit = 1.0 ... 8.0

    /// The slice of `fitted` that fills the frame at this magnification.
    ///
    /// - Parameters:
    ///   - anchor: where the cue aims, 0…1 across the picture, top-left origin.
    ///   - magnification: 1 is the whole picture; 2 shows half of each edge.
    ///   - fitted: the picture's rect inside the preview.
    static func viewport(anchor: CGPoint, magnification: Double, in fitted: CGRect) -> CGRect {
        let zoom = max(magnification, 1)
        let size = CGSize(width: fitted.width / zoom, height: fitted.height / zoom)
        let wanted = CGPoint(
            x: fitted.minX + clamp(anchor.x) * fitted.width,
            y: fitted.minY + clamp(anchor.y) * fitted.height
        )
        // Stopped at the edges rather than allowed past them: the render has nothing to
        // show outside the recording, so a target drawn there would not be what plays.
        let centre = CGPoint(
            x: min(max(wanted.x, fitted.minX + size.width / 2), fitted.maxX - size.width / 2),
            y: min(max(wanted.y, fitted.minY + size.height / 2), fitted.maxY - size.height / 2)
        )
        return CGRect(
            x: centre.x - size.width / 2,
            y: centre.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The anchor a point on the picture stands for.
    static func anchor(at point: CGPoint, in fitted: CGRect) -> CGPoint {
        guard fitted.width > 0, fitted.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: clamp((point.x - fitted.minX) / fitted.width),
            y: clamp((point.y - fitted.minY) / fitted.height)
        )
    }

    /// The magnification a corner dragged to `point` implies.
    ///
    /// Measured on the axis that has travelled furthest from the anchor, so a drag that is
    /// mostly sideways still reads as a drag, and the frame keeps the picture's shape
    /// instead of becoming whatever rectangle the pointer traced.
    static func magnification(
        draggingCornerTo point: CGPoint,
        anchor: CGPoint,
        in fitted: CGRect,
        limit: ClosedRange<Double> = magnificationLimit
    ) -> Double {
        guard fitted.width > 0, fitted.height > 0 else { return limit.lowerBound }
        let centre = CGPoint(
            x: fitted.minX + clamp(anchor.x) * fitted.width,
            y: fitted.minY + clamp(anchor.y) * fitted.height
        )
        let halfWidth = abs(point.x - centre.x)
        let halfHeight = abs(point.y - centre.y)
        // Whichever axis the pointer has pulled further decides, in units of the picture.
        let byWidth = fitted.width / max(halfWidth * 2, 1)
        let byHeight = fitted.height / max(halfHeight * 2, 1)
        let zoom = min(byWidth, byHeight)
        return min(max(zoom, limit.lowerBound), limit.upperBound)
    }

    /// Where a recorded pointer sample sits on the preview.
    static func point(forPixel pixel: CGPoint, in pixelSize: CGSize, fitted: CGRect) -> CGPoint? {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return CGPoint(
            x: fitted.minX + clamp(pixel.x / pixelSize.width) * fitted.width,
            y: fitted.minY + clamp(pixel.y / pixelSize.height) * fitted.height
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }
}
