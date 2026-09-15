import CoreGraphics
import Foundation
import QuartzCore

/// A 3×3 projective transform (docs/09 U1.2).
///
/// An affine transform cannot express perspective: parallel lines stay parallel under
/// `CGAffineTransform`, and a tilted screenshot's edges converge. The extra row is exactly
/// what that convergence needs — the third coordinate divides, so points further "away"
/// land closer together.
///
/// Written out rather than taken from a matrix library because the editor needs the
/// *inverse* as much as the forward map: hit-testing a click on a tilted image means
/// asking which pixel is under the pointer, and that is the inverse applied to a mouse
/// location. A transform that can only go one way makes a tilted image uneditable.
public struct Homography: Equatable, Sendable {
    /// Row-major elements, named row-then-column: `m21` is row 2, column 1.
    ///
    /// Named rather than `a`…`i` because the inverse and the composition below are long
    /// enough that a transposition is easy to write and impossible to spot.
    public var m11: CGFloat, m12: CGFloat, m13: CGFloat
    public var m21: CGFloat, m22: CGFloat, m23: CGFloat
    public var m31: CGFloat, m32: CGFloat, m33: CGFloat

    public init(
        m11: CGFloat,
        m12: CGFloat,
        m13: CGFloat,
        m21: CGFloat,
        m22: CGFloat,
        m23: CGFloat,
        m31: CGFloat,
        m32: CGFloat,
        m33: CGFloat
    ) {
        self.m11 = m11
        self.m12 = m12
        self.m13 = m13
        self.m21 = m21
        self.m22 = m22
        self.m23 = m23
        self.m31 = m31
        self.m32 = m32
        self.m33 = m33
    }

    public static let identity = Homography(
        m11: 1,
        m12: 0,
        m13: 0,
        m21: 0,
        m22: 1,
        m23: 0,
        m31: 0,
        m32: 0,
        m33: 1
    )

    public var isIdentity: Bool {
        self == .identity
    }

    /// Applies the transform, dividing through by the third coordinate.
    ///
    /// Returns nil when that coordinate is zero, which is a point on the horizon — the
    /// projection of something exactly level with the camera. It has no image on the
    /// screen, and pretending otherwise puts a click at infinity.
    public func map(_ point: CGPoint) -> CGPoint? {
        let weight = m31 * point.x + m32 * point.y + m33
        guard abs(weight) > 1e-9 else { return nil }
        return CGPoint(
            x: (m11 * point.x + m12 * point.y + m13) / weight,
            y: (m21 * point.x + m22 * point.y + m23) / weight
        )
    }

    public var determinant: CGFloat {
        m11 * (m22 * m33 - m23 * m32)
            - m12 * (m21 * m33 - m23 * m31)
            + m13 * (m21 * m32 - m22 * m31)
    }

    /// The inverse, or nil for a degenerate transform — a camera that has folded the image
    /// onto a line, which no amount of clicking can be mapped back through.
    public var inverted: Homography? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        return Homography(
            m11: (m22 * m33 - m23 * m32) / det,
            m12: (m13 * m32 - m12 * m33) / det,
            m13: (m12 * m23 - m13 * m22) / det,
            m21: (m23 * m31 - m21 * m33) / det,
            m22: (m11 * m33 - m13 * m31) / det,
            m23: (m13 * m21 - m11 * m23) / det,
            m31: (m21 * m32 - m22 * m31) / det,
            m32: (m12 * m31 - m11 * m32) / det,
            m33: (m11 * m22 - m12 * m21) / det
        )
    }

    /// `self` applied after `other`.
    public func concatenating(_ other: Homography) -> Homography {
        Homography(
            m11: m11 * other.m11 + m12 * other.m21 + m13 * other.m31,
            m12: m11 * other.m12 + m12 * other.m22 + m13 * other.m32,
            m13: m11 * other.m13 + m12 * other.m23 + m13 * other.m33,
            m21: m21 * other.m11 + m22 * other.m21 + m23 * other.m31,
            m22: m21 * other.m12 + m22 * other.m22 + m23 * other.m32,
            m23: m21 * other.m13 + m22 * other.m23 + m23 * other.m33,
            m31: m31 * other.m11 + m32 * other.m21 + m33 * other.m31,
            m32: m31 * other.m12 + m32 * other.m22 + m33 * other.m32,
            m33: m31 * other.m13 + m32 * other.m23 + m33 * other.m33
        )
    }

    /// The transform taking the unit square to `quad`.
    ///
    /// The classical four-point solution rather than a general least-squares fit: four
    /// correspondences determine a homography exactly, and the closed form is both faster
    /// and free of the numerical drift an iterative solve would introduce between the
    /// canvas and the export.
    public static func unitSquare(to quad: CameraQuad) -> Homography {
        let topLeft = quad.topLeft
        let topRight = quad.topRight
        let bottomRight = quad.bottomRight
        let bottomLeft = quad.bottomLeft

        let sumX = topLeft.x - topRight.x + bottomRight.x - bottomLeft.x
        let sumY = topLeft.y - topRight.y + bottomRight.y - bottomLeft.y

        // A parallelogram has no vanishing point, so the projective terms drop out and the
        // general solve would divide by zero.
        if abs(sumX) < 1e-9, abs(sumY) < 1e-9 {
            return Homography(
                m11: topRight.x - topLeft.x,
                m12: bottomLeft.x - topLeft.x,
                m13: topLeft.x,
                m21: topRight.y - topLeft.y,
                m22: bottomLeft.y - topLeft.y,
                m23: topLeft.y,
                m31: 0,
                m32: 0,
                m33: 1
            )
        }

        let acrossTop = topRight.x - bottomRight.x
        let acrossSide = bottomLeft.x - bottomRight.x
        let downTop = topRight.y - bottomRight.y
        let downSide = bottomLeft.y - bottomRight.y
        let denominator = acrossTop * downSide - acrossSide * downTop
        guard abs(denominator) > 1e-12 else { return .identity }

        let perspectiveX = (sumX * downSide - acrossSide * sumY) / denominator
        let perspectiveY = (acrossTop * sumY - sumX * downTop) / denominator
        return Homography(
            m11: topRight.x - topLeft.x + perspectiveX * topRight.x,
            m12: bottomLeft.x - topLeft.x + perspectiveY * bottomLeft.x,
            m13: topLeft.x,
            m21: topRight.y - topLeft.y + perspectiveX * topRight.y,
            m22: bottomLeft.y - topLeft.y + perspectiveY * bottomLeft.y,
            m23: topLeft.y,
            m31: perspectiveX,
            m32: perspectiveY,
            m33: 1
        )
    }

    /// The transform taking `rect` to `quad`, corner for corner.
    public static func rect(_ rect: CGRect, to quad: CameraQuad) -> Homography {
        guard rect.width > 0, rect.height > 0 else { return .identity }
        // Rect to unit square first, then unit square to the quad.
        let normalize = Homography(
            m11: 1 / rect.width,
            m12: 0,
            m13: -rect.minX / rect.width,
            m21: 0,
            m22: 1 / rect.height,
            m23: -rect.minY / rect.height,
            m31: 0,
            m32: 0,
            m33: 1
        )
        return unitSquare(to: quad).concatenating(normalize)
    }

    /// The same map as a layer transform (docs/16 ED-4).
    ///
    /// Core Animation multiplies a column vector, so the projective row of the 3×3 lands
    /// in `m14`/`m24`/`m44`. Applying this to a corner must match `map(_:)`.
    public var caTransform3D: CATransform3D {
        CATransform3D(
            m11: m11,
            m12: m21,
            m13: 0,
            m14: m31,
            m21: m12,
            m22: m22,
            m23: 0,
            m24: m32,
            m31: 0,
            m32: 0,
            m33: 1,
            m34: 0,
            m41: m13,
            m42: m23,
            m43: 0,
            m44: m33
        )
    }

    /// Applies a Core Animation matrix the same way `map` applies the 3×3.
    public static func map(_ transform: CATransform3D, _ point: CGPoint) -> CGPoint? {
        let x = transform.m11 * point.x + transform.m21 * point.y + transform.m41
        let y = transform.m12 * point.x + transform.m22 * point.y + transform.m42
        let weight = transform.m14 * point.x + transform.m24 * point.y + transform.m44
        guard abs(weight) > 1e-9 else { return nil }
        return CGPoint(x: x / weight, y: y / weight)
    }
}

/// Four corners, in the model's top-left space (docs/09 U1.2).
///
/// Named corners rather than an array because every consumer — the homography solve, the
/// CoreImage filter, the selection handles — needs to know *which* corner is which, and an
/// array invites getting the winding order wrong exactly once.
public struct CameraQuad: Equatable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public init(rect: CGRect) {
        self.init(
            topLeft: CGPoint(x: rect.minX, y: rect.minY),
            topRight: CGPoint(x: rect.maxX, y: rect.minY),
            bottomRight: CGPoint(x: rect.maxX, y: rect.maxY),
            bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        )
    }

    public var corners: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    /// The axis-aligned box the quad occupies, for sizing a render.
    public var boundingBox: CGRect {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The same quad in a bottom-left coordinate space of the given height, which is what
    /// CoreImage wants.
    public func flipped(inHeight height: CGFloat) -> CameraQuad {
        func flip(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: height - point.y)
        }
        return CameraQuad(
            topLeft: flip(topLeft),
            topRight: flip(topRight),
            bottomRight: flip(bottomRight),
            bottomLeft: flip(bottomLeft)
        )
    }
}
