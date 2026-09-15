import CoreGraphics
import Foundation

/// Every spotlight on a document, drawn as one dim with every hole punched out (docs/16 ED-9).
///
/// Stacking per-spotlight dims made two holes darker than one, and a spotlight later in
/// z-order dimmed arrows drawn earlier. One even-odd fill after redactions and before the
/// other shapes matches Screendrop and keeps both holes equally bright.
public struct SpotlightComposite: Equatable, Sendable {
    public struct Hole: Equatable, Sendable {
        public var rect: CGRect
        public var cornerRadius: CGFloat

        public init(rect: CGRect, cornerRadius: CGFloat) {
            self.rect = rect.standardized
            self.cornerRadius = max(cornerRadius, 0)
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
            holes.append(Hole(rect: spec.rect, cornerRadius: spec.fittedCornerRadius))
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
            let radius = min(hole.cornerRadius, min(hole.rect.width, hole.rect.height) / 2)
            path.addRoundedRect(in: hole.rect, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }
}
