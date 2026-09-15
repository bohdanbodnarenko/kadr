import CoreGraphics
import Foundation

/// Dims the rest of the canvas so one region stays bright (docs/03 §3 P2, CleanShot §8).
///
/// The stored geometry is the hole, not the overlay: the overlay always covers the
/// canvas, and the hole is what the user resizes. Smooth rounded corners, because a
/// hard rectangle looks like a crop rather than a focus.
public struct SpotlightSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var rect: CGRect
    /// How opaque the dim overlay is. Zero is off; one is a blackout.
    public var dimOpacity: CGFloat
    public var cornerRadius: CGFloat
    public var rotation: CGFloat

    public static let dimOpacityRange: ClosedRange<CGFloat> = 0.15 ... 0.85
    public static let defaultDimOpacity: CGFloat = 0.55
    public static let cornerRadiusRange: ClosedRange<CGFloat> = 0 ... 48
    public static let defaultCornerRadius: CGFloat = 16

    public init(
        id: AnnotationID = AnnotationID(),
        rect: CGRect,
        dimOpacity: CGFloat = SpotlightSpec.defaultDimOpacity,
        cornerRadius: CGFloat = SpotlightSpec.defaultCornerRadius,
        rotation: CGFloat = 0
    ) {
        self.id = id
        self.rect = rect
        self.dimOpacity = Self.clampedDim(dimOpacity)
        self.cornerRadius = Self.clampedCorner(cornerRadius)
        self.rotation = rotation
    }

    public func withDimOpacity(_ value: CGFloat) -> SpotlightSpec {
        var copy = self
        copy.dimOpacity = Self.clampedDim(value)
        return copy
    }

    public func withCornerRadius(_ value: CGFloat) -> SpotlightSpec {
        var copy = self
        copy.cornerRadius = Self.clampedCorner(value)
        return copy
    }

    /// The radius that actually fits this hole — a 20-point box cannot round by 48.
    public var fittedCornerRadius: CGFloat {
        min(cornerRadius, min(rect.width, rect.height) / 2)
    }

    static func clampedDim(_ value: CGFloat) -> CGFloat {
        min(max(value, dimOpacityRange.lowerBound), dimOpacityRange.upperBound)
    }

    static func clampedCorner(_ value: CGFloat) -> CGFloat {
        min(max(value, cornerRadiusRange.lowerBound), cornerRadiusRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case id, rect, dimOpacity, cornerRadius, rotation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(AnnotationID.self, forKey: .id),
            rect: container.decode(CGRect.self, forKey: .rect),
            dimOpacity: container.decodeIfPresent(CGFloat.self, forKey: .dimOpacity) ?? Self.defaultDimOpacity,
            cornerRadius: container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? Self.defaultCornerRadius,
            rotation: container.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        )
    }
}
