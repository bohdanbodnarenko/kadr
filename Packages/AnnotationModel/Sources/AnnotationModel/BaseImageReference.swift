import CoreGraphics
import Foundation

/// The immutable image an annotation document sits on (docs/04 §6).
public struct BaseImageReference: Codable, Hashable, Sendable {
    /// Size in points; the pixel size is this multiplied by `scale`.
    public var size: CGSize
    public var scale: CGFloat
    /// How the capture is shown and exported. The pixels themselves never rotate.
    public var orientation: CanvasOrientation
    /// The opaque capture inside a transparent margin, in points — a window captured with
    /// its shadow, whose PNG is the window plus a soft, mostly transparent border. `nil`
    /// when the capture has no such margin, or it has not been measured.
    ///
    /// Beautify composes this rather than the whole image (see `AnnotationDocument
    /// .contentRect`): the card, its corners and its shadow belong on the window, not on the
    /// invisible rectangle around it.
    public var visibleBounds: CGRect?

    public init(
        size: CGSize,
        scale: CGFloat = 2,
        orientation: CanvasOrientation = .identity,
        visibleBounds: CGRect? = nil
    ) {
        self.size = size
        self.scale = max(scale, 1)
        self.orientation = orientation
        self.visibleBounds = Self.validated(visibleBounds, size: size)
    }

    /// A visible region worth composing: inside the image, not empty, and not the image.
    static func validated(_ rect: CGRect?, size: CGSize) -> CGRect? {
        guard let rect else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        let clipped = rect.standardized.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1, clipped != bounds else {
            return nil
        }
        return clipped
    }

    public var pixelSize: CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    public var bounds: CGRect {
        CGRect(origin: .zero, size: size)
    }

    private enum CodingKeys: String, CodingKey {
        case size
        case scale
        case orientation
        case visibleBounds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decode(CGSize.self, forKey: .size)
        scale = try max(container.decode(CGFloat.self, forKey: .scale), 1)
        orientation = try container.decodeIfPresent(CanvasOrientation.self, forKey: .orientation)
            ?? .identity
        visibleBounds = try Self.validated(
            container.decodeIfPresent(CGRect.self, forKey: .visibleBounds),
            size: size
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(size, forKey: .size)
        try container.encode(scale, forKey: .scale)
        if !orientation.isIdentity {
            try container.encode(orientation, forKey: .orientation)
        }
        try container.encodeIfPresent(visibleBounds, forKey: .visibleBounds)
    }
}
