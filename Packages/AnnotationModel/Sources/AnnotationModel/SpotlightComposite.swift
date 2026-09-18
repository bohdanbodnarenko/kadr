import CoreGraphics
import Foundation

/// Every spotlight on a document, drawn as one dim with every hole punched out (docs/16 ED-9).
///
/// Stacking per-spotlight dims made two holes darker than one, and a spotlight later in
/// z-order dimmed arrows drawn earlier. One even-odd fill after redactions and before the
/// other shapes keeps both holes equally bright.
public struct SpotlightComposite: Equatable, Sendable {
    public struct Hole: Equatable, Sendable {
        public var rect: CGRect
        public var cornerRadius: CGFloat
        /// Turned about the hole's centre, like the spotlight it comes from (docs/16 ED-10).
        public var rotation: CGFloat

        public init(rect: CGRect, cornerRadius: CGFloat, rotation: CGFloat = 0) {
            self.rect = rect.standardized
            self.cornerRadius = max(cornerRadius, 0)
            self.rotation = rotation
        }

        /// The hole's outline, in the same space as `rect` shifted by `offset`.
        public func path(offsetBy offset: CGSize = .zero) -> CGPath {
            let local = rect.offsetBy(dx: offset.width, dy: offset.height)
            let radius = min(cornerRadius, min(local.width, local.height) / 2)
            var turn = AnnotationRotation.transform(
                radians: rotation,
                around: CGPoint(x: local.midX, y: local.midY)
            )
            return CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: &turn)
        }
    }

    /// The strongest dim among the spotlights — stacking would darken overlapping holes.
    public var dimOpacity: CGFloat
    public var holes: [Hole]

    public init(dimOpacity: CGFloat, holes: [Hole]) {
        self.dimOpacity = min(max(dimOpacity, 0), 1)
        self.holes = holes
    }

    /// `nil` when the document has no spotlights.
    public static func from(commands: [AnnotationCommand]) -> SpotlightComposite? {
        var holes: [Hole] = []
        var opacity: CGFloat = 0
        for command in commands {
            guard case let .spotlight(spec) = command else { continue }
            holes.append(Hole(rect: spec.rect, cornerRadius: spec.fittedCornerRadius, rotation: spec.rotation))
            opacity = max(opacity, spec.dimOpacity)
        }
        guard !holes.isEmpty else { return nil }
        return SpotlightComposite(dimOpacity: opacity, holes: holes)
    }

    /// Even-odd path: the canvas rect, then every hole.
    public func path(in canvas: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(canvas)
        for hole in holes {
            path.addPath(hole.path())
        }
        return path
    }
}
