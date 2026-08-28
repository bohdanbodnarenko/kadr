import CoreGraphics
import Foundation

/// A virtual camera looking at the capture (docs/09 U1.2).
///
/// The effect is the "screenshot on a tilted plane" look, and the reason it is a camera
/// rather than a canned set of skews is that the canned version falls apart the moment two
/// of them are combined: a tilt plus a rotation is not the sum of a tilt and a rotation.
/// A real pinhole projection composes correctly by construction, and gives the FOV knob
/// meaning — the difference between a gentle isometric lean and a dramatic wide-angle one.
///
/// Angles are degrees because the inspector shows degrees and a model that stores radians
/// converts twice for no reason.
public struct AnnotationCameraSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    /// Rotation about the horizontal axis: the top of the image leans away or towards.
    public var tiltDegrees: CGFloat
    /// Rotation about the vertical axis: the image swings left or right.
    public var orbitDegrees: CGFloat
    /// Rotation in the picture plane, which stays a plain rotation at any FOV.
    public var rollDegrees: CGFloat
    /// How wide the lens is. Small is nearly orthographic; large exaggerates depth.
    public var fieldOfViewDegrees: CGFloat
    /// Scale applied after projection.
    public var zoom: CGFloat
    /// Offset after projection, as a fraction of the content's size — so a pan carries
    /// between captures the way every other beautify metric does.
    public var pan: CGPoint

    public init(
        id: AnnotationID = AnnotationID(),
        tiltDegrees: CGFloat = 0,
        orbitDegrees: CGFloat = 0,
        rollDegrees: CGFloat = 0,
        fieldOfViewDegrees: CGFloat = 45,
        zoom: CGFloat = 1,
        pan: CGPoint = .zero
    ) {
        self.id = id
        self.tiltDegrees = min(max(tiltDegrees, -Self.maximumTilt), Self.maximumTilt)
        self.orbitDegrees = min(max(orbitDegrees, -Self.maximumTilt), Self.maximumTilt)
        self.rollDegrees = rollDegrees
        self.fieldOfViewDegrees = min(max(fieldOfViewDegrees, Self.minimumFieldOfView), Self.maximumFieldOfView)
        self.zoom = min(max(zoom, Self.minimumZoom), Self.maximumZoom)
        self.pan = pan
    }

    /// Past roughly this the plane turns edge-on and the projection degenerates. Clamped
    /// rather than guarded at render time so the *model* can never hold a camera that
    /// cannot be inverted, and hit-testing therefore always works.
    public static let maximumTilt: CGFloat = 75
    public static let minimumFieldOfView: CGFloat = 10
    public static let maximumFieldOfView: CGFloat = 120
    public static let minimumZoom: CGFloat = 0.2
    public static let maximumZoom: CGFloat = 4

    /// Whether this camera does anything at all. An identity camera is skipped entirely
    /// rather than round-tripped through CoreImage for nothing.
    public var isIdentity: Bool {
        tiltDegrees == 0 && orbitDegrees == 0 && rollDegrees == 0
            && zoom == 1 && pan == .zero
    }

    private enum CodingKeys: String, CodingKey {
        case id, tiltDegrees, orbitDegrees, rollDegrees, fieldOfViewDegrees, zoom, pan
    }

    /// Every field defaults, so a camera written by a later Kadr with more knobs still
    /// opens here (docs/08 §2.6).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decodeIfPresent(AnnotationID.self, forKey: .id) ?? AnnotationID(),
            tiltDegrees: container.decodeIfPresent(CGFloat.self, forKey: .tiltDegrees) ?? 0,
            orbitDegrees: container.decodeIfPresent(CGFloat.self, forKey: .orbitDegrees) ?? 0,
            rollDegrees: container.decodeIfPresent(CGFloat.self, forKey: .rollDegrees) ?? 0,
            fieldOfViewDegrees: container.decodeIfPresent(CGFloat.self, forKey: .fieldOfViewDegrees) ?? 45,
            zoom: container.decodeIfPresent(CGFloat.self, forKey: .zoom) ?? 1,
            pan: container.decodeIfPresent(CGPoint.self, forKey: .pan) ?? .zero
        )
    }

    // MARK: - Presets

    public static let identity = AnnotationCameraSpec()

    /// A gentle lean, the one people reach for on a landing page.
    public static let lean = AnnotationCameraSpec(tiltDegrees: 12, orbitDegrees: -16, fieldOfViewDegrees: 35)
    /// A hard three-quarter view.
    public static let hero = AnnotationCameraSpec(tiltDegrees: 20, orbitDegrees: -28, fieldOfViewDegrees: 55)
    /// Looking down at the page, as if it were lying on a desk.
    public static let overhead = AnnotationCameraSpec(tiltDegrees: 38, fieldOfViewDegrees: 50)
}

/// Where a camera puts each corner of the capture (docs/09 U1.2).
///
/// Pure, and separate from the spec, because this is the piece three things need to agree
/// on: the renderer projects through it, hit-testing inverts it, and the selection handles
/// are drawn on it. A struct computed once from the spec is how they cannot disagree.
public struct AnnotationCameraGeometry: Equatable, Sendable {
    /// Where the content's four corners land.
    public var quad: CameraQuad
    /// Content space to canvas space.
    public var transform: Homography
    /// Canvas space back to content space, for hit-testing. Nil only for a camera the
    /// clamps in `AnnotationCameraSpec` are meant to make unreachable.
    public var inverse: Homography?

    public init(spec: AnnotationCameraSpec, contentRect: CGRect) {
        let quad = Self.project(spec: spec, contentRect: contentRect)
        self.quad = quad
        transform = Homography.rect(contentRect, to: quad)
        inverse = transform.inverted
    }

    /// A canvas point in content coordinates, or nil if it is not on the image at all.
    public func contentPoint(from canvasPoint: CGPoint) -> CGPoint? {
        inverse?.map(canvasPoint)
    }

    /// A content point in canvas coordinates.
    public func canvasPoint(from contentPoint: CGPoint) -> CGPoint? {
        transform.map(contentPoint)
    }

    /// Projects the content rect's corners through the camera.
    ///
    /// The model: the capture is a flat rectangle centred on the origin in the z = 0 plane;
    /// the camera sits back along +z looking at it. Rotating the rectangle and dividing by
    /// depth is the whole of perspective.
    ///
    /// The camera's distance is derived from the field of view so that an untilted image
    /// exactly fills its original rect. Without that, changing the FOV alone would resize
    /// the picture, and the knob would read as a zoom rather than as a lens.
    static func project(spec: AnnotationCameraSpec, contentRect: CGRect) -> CameraQuad {
        guard contentRect.width > 0, contentRect.height > 0 else { return CameraQuad(rect: contentRect) }

        let halfWidth = contentRect.width / 2
        let halfHeight = contentRect.height / 2
        let fov = spec.fieldOfViewDegrees * .pi / 180
        // tan(fov / 2) = halfHeight / distance.
        let distance = halfHeight / tan(fov / 2)

        let tilt = spec.tiltDegrees * .pi / 180
        let orbit = spec.orbitDegrees * .pi / 180
        let roll = spec.rollDegrees * .pi / 180

        func project(_ corner: CGPoint) -> CGPoint {
            // The corner in the plane, and its depth once the plane has been rotated.
            var across = corner.x
            var down = corner.y
            var depth = CGFloat(0)

            // Tilt about the horizontal axis: the top edge leans away from the viewer.
            (down, depth) = (
                down * cos(tilt) - depth * sin(tilt),
                down * sin(tilt) + depth * cos(tilt)
            )

            // Orbit about the vertical axis.
            (across, depth) = (
                across * cos(orbit) + depth * sin(orbit),
                -across * sin(orbit) + depth * cos(orbit)
            )

            // Roll in the picture plane.
            (across, down) = (
                across * cos(roll) - down * sin(roll),
                across * sin(roll) + down * cos(roll)
            )

            // Perspective divide. A corner rotated towards the viewer has positive depth
            // and is therefore magnified; one rotated away shrinks.
            let toCamera = distance - depth
            // The clamps on tilt and orbit keep this positive; the guard is what makes
            // that a fact rather than a hope.
            let scale = toCamera > 1e-6 ? distance / toCamera : 1

            return CGPoint(
                x: across * scale * spec.zoom + spec.pan.x * contentRect.width + contentRect.midX,
                y: down * scale * spec.zoom + spec.pan.y * contentRect.height + contentRect.midY
            )
        }

        return CameraQuad(
            topLeft: project(CGPoint(x: -halfWidth, y: -halfHeight)),
            topRight: project(CGPoint(x: halfWidth, y: -halfHeight)),
            bottomRight: project(CGPoint(x: halfWidth, y: halfHeight)),
            bottomLeft: project(CGPoint(x: -halfWidth, y: halfHeight))
        )
    }
}
