import CoreGraphics
import Foundation

/// How a progressive blur falls off (docs/09 U1.3).
public enum ProgressiveBlurShape: String, Codable, CaseIterable, Sendable {
    /// Sharp in the middle, blurred towards the edges — the "focus on this" look.
    case radial
    /// Sharp along one edge, blurred towards the opposite one, at any angle.
    case directional

    public var title: String {
        switch self {
        case .radial: "Radial"
        case .directional: "Directional"
        }
    }
}

/// What a progressive blur covers (docs/09 U1.3).
public enum ProgressiveBlurExtent: String, Codable, CaseIterable, Sendable {
    /// Only the capture. The beautify backdrop around it stays crisp, so the screenshot
    /// looks like a photograph of a screen with shallow depth of field.
    case clipped
    /// The whole composed canvas, backdrop included, as if the camera were focused on one
    /// part of the scene.
    case scene

    public var title: String {
        switch self {
        case .clipped: "Capture only"
        case .scene: "Whole canvas"
        }
    }
}

/// A blur that varies across the image (docs/09 U1.3).
///
/// Not the same thing as the redaction blur, and deliberately a separate type: a redaction
/// is a security claim burned irreversibly into the pixels over a rectangle the user drew,
/// while this is a decorative gradient over the whole picture. Sharing one spec between
/// them would eventually mean sharing one code path, and a decorative effect must never be
/// able to reach the code that makes a secret unrecoverable.
///
/// Everything is normalized — the radius to the content's shortest edge, the centre and the
/// falloff to the content's own size — so a blur carries between captures the way the rest
/// of the beautify metrics do.
public struct ProgressiveBlurSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var shape: ProgressiveBlurShape
    public var extent: ProgressiveBlurExtent
    /// The strongest blur anywhere in the image.
    public var radius: BeautifyMetric
    /// Where the sharp region sits, in unit coordinates of the target rect.
    public var center: CGPoint
    /// Where the blur begins, as a fraction of the target's shortest edge. Everything
    /// closer to the centre than this stays perfectly sharp.
    public var focusRadius: CGFloat
    /// Where the blur reaches full strength. Must be beyond `focusRadius` to be a gradient
    /// rather than a hard edge.
    public var falloffRadius: CGFloat
    /// Which way a directional blur runs, measured like every other angle here: from the
    /// positive x-axis, clockwise in the model's top-left space.
    public var angleDegrees: CGFloat
    /// Blurs the middle and leaves the edges sharp — a vignette in reverse, useful for
    /// hiding a face or a name in the centre of a shot without drawing a box round it.
    public var isInverted: Bool

    public init(
        id: AnnotationID = AnnotationID(),
        shape: ProgressiveBlurShape = .radial,
        extent: ProgressiveBlurExtent = .clipped,
        radius: BeautifyMetric = .relative(0.06),
        center: CGPoint = CGPoint(x: 0.5, y: 0.5),
        focusRadius: CGFloat = 0.25,
        falloffRadius: CGFloat = 0.75,
        angleDegrees: CGFloat = 90,
        isInverted: Bool = false
    ) {
        self.id = id
        self.shape = shape
        self.extent = extent
        self.radius = radius
        self.center = CGPoint(
            x: min(max(center.x, -1), 2),
            y: min(max(center.y, -1), 2)
        )
        // Ordered on the way in, so no renderer has to cope with a falloff inside the
        // focus — which would be a divide by a negative and a mask that runs backwards.
        let low = max(min(focusRadius, falloffRadius), 0)
        let high = max(focusRadius, falloffRadius)
        self.focusRadius = low
        self.falloffRadius = max(high, low + Self.minimumFalloff)
        self.angleDegrees = angleDegrees
        self.isInverted = isInverted
    }

    /// The smallest gap between focus and falloff. Below this the gradient is a hard edge,
    /// which reads as a bug rather than as an effect.
    public static let minimumFalloff: CGFloat = 0.02

    /// Whether this blur would do anything.
    public var isIdentity: Bool {
        radius.isZero
    }

    private enum CodingKeys: String, CodingKey {
        case id, shape, extent, radius, center, focusRadius, falloffRadius, angleDegrees, isInverted
    }

    /// Every field defaults, so a spec written by a later Kadr still opens (docs/08 §2.6).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decodeIfPresent(AnnotationID.self, forKey: .id) ?? AnnotationID(),
            shape: container.decodeIfPresent(ProgressiveBlurShape.self, forKey: .shape) ?? .radial,
            extent: container.decodeIfPresent(ProgressiveBlurExtent.self, forKey: .extent) ?? .clipped,
            radius: container.decodeIfPresent(BeautifyMetric.self, forKey: .radius) ?? .relative(0.06),
            center: container.decodeIfPresent(CGPoint.self, forKey: .center)
                ?? CGPoint(x: 0.5, y: 0.5),
            focusRadius: container.decodeIfPresent(CGFloat.self, forKey: .focusRadius) ?? 0.25,
            falloffRadius: container.decodeIfPresent(CGFloat.self, forKey: .falloffRadius) ?? 0.75,
            angleDegrees: container.decodeIfPresent(CGFloat.self, forKey: .angleDegrees) ?? 90,
            isInverted: container.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
        )
    }

    // MARK: - Presets

    /// Sharp in the middle, soft at the corners.
    public static let focus = ProgressiveBlurSpec()
    /// Sharp at the top, softening downwards — the look for a long page screenshot whose
    /// bottom half is filler.
    public static let fade = ProgressiveBlurSpec(
        shape: .directional,
        radius: .relative(0.05),
        focusRadius: 0.1,
        falloffRadius: 0.9,
        angleDegrees: 90
    )
    /// The middle goes soft instead of the edges.
    public static let obscureCentre = ProgressiveBlurSpec(
        radius: .relative(0.08),
        focusRadius: 0.3,
        falloffRadius: 0.6,
        isInverted: true
    )
}

/// The gradient a progressive blur uses as its mask (docs/09 U1.3).
///
/// Pure geometry, computed here rather than in the renderer, for the reason every other
/// piece of this is: the live canvas, the export and any preview must agree, and the only
/// way three call sites agree is that none of them does the arithmetic. It is also the only
/// part of a blur that can be checked without rendering anything.
public struct ProgressiveBlurMask: Equatable, Sendable {
    /// White means fully blurred, black means sharp — the convention
    /// `CIMaskedVariableBlur` expects.
    public var isRadial: Bool
    /// Radial: the centre of the sharp region, in the target's own coordinates.
    public var center: CGPoint
    /// Radial: where the blur starts and where it reaches full strength, in points.
    public var innerRadius: CGFloat
    public var outerRadius: CGFloat
    /// Directional: the two ends of the ramp, in the target's own coordinates.
    public var start: CGPoint
    public var end: CGPoint
    /// The strongest blur, in points.
    public var blurRadius: CGFloat
    /// Whether the ramp runs the other way — sharp outside, blurred inside.
    public var isInverted: Bool

    /// Resolves a spec against the rect it applies to.
    public static func resolve(_ spec: ProgressiveBlurSpec, in rect: CGRect) -> ProgressiveBlurMask {
        let shortestEdge = max(min(rect.width, rect.height), 1)
        let center = CGPoint(
            x: rect.minX + rect.width * spec.center.x,
            y: rect.minY + rect.height * spec.center.y
        )
        // The falloff reaches to the far corner at 1.0, so "0.75" means most of the way
        // out on any aspect ratio rather than three quarters of the narrow side.
        let reach = hypot(rect.width, rect.height) / 2

        // A directional ramp runs through the centre, perpendicular to nothing in
        // particular: the angle is the direction of increasing blur.
        let angle = spec.angleDegrees * .pi / 180
        let axis = CGPoint(x: cos(angle), y: sin(angle))
        let origin = CGPoint(x: rect.midX, y: rect.midY)

        return ProgressiveBlurMask(
            isRadial: spec.shape == .radial,
            center: center,
            innerRadius: spec.focusRadius * reach,
            outerRadius: spec.falloffRadius * reach,
            start: CGPoint(
                x: origin.x + axis.x * (spec.focusRadius - 0.5) * 2 * reach,
                y: origin.y + axis.y * (spec.focusRadius - 0.5) * 2 * reach
            ),
            end: CGPoint(
                x: origin.x + axis.x * (spec.falloffRadius - 0.5) * 2 * reach,
                y: origin.y + axis.y * (spec.falloffRadius - 0.5) * 2 * reach
            ),
            blurRadius: spec.radius.resolved(shortestEdge: shortestEdge),
            isInverted: spec.isInverted
        )
    }
}
