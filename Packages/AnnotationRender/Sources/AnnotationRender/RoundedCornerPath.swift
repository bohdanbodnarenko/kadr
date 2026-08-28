import AnnotationModel
import CoreGraphics
import Foundation

/// Builds a rounded rectangle whose four corners can differ (docs/09 U1.1).
///
/// `CGPath(roundedRect:cornerWidth:cornerHeight:)` takes one radius for all four, which is
/// exactly what the stuck-edge look cannot use: a capture bleeding off the bottom of the
/// frame needs its bottom corners square and its top two round, in one path.
public enum RoundedCornerPath {
    /// The path, in the caller's own coordinate space.
    ///
    /// Corner names are in the model's top-left space; a caller drawing in a flipped
    /// context is responsible for its own transform, as everywhere else in the renderer.
    public static func path(in rect: CGRect, corners: BeautifyCorners) -> CGPath {
        let corners = corners.clamped(to: rect)
        guard corners.largest > 0 else { return CGPath(rect: rect, transform: nil) }

        let path = CGMutablePath()
        // Arcs rather than curves so the corners are true circular quadrants: an
        // approximation drifts visibly against the shadow drawn from the same path.
        path.move(to: CGPoint(x: rect.minX + corners.topLeading, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - corners.topTrailing, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + corners.topTrailing),
            radius: corners.topTrailing
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corners.bottomTrailing))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - corners.bottomTrailing, y: rect.maxY),
            radius: corners.bottomTrailing
        )
        path.addLine(to: CGPoint(x: rect.minX + corners.bottomLeading, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - corners.bottomLeading),
            radius: corners.bottomLeading
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corners.topLeading))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + corners.topLeading, y: rect.minY),
            radius: corners.topLeading
        )
        path.closeSubpath()
        return path
    }
}
