import CoreGraphics
import Foundation

/// A mark laid over the finished image (docs/09 U1.4).
///
/// Two shapes of the same idea: one mark in a corner, which is a signature, or a rotated
/// tile repeated across the whole picture, which is a claim of ownership that survives
/// being cropped. Both are the same text drawn at the same angle, so they are one type
/// rather than two.
///
/// Everything is normalized to the canvas's shortest edge, like the rest of the beautify
/// metrics, so a watermark keeps its proportions on any capture.
public struct WatermarkSpec: Codable, Hashable, Sendable {
    public var id: AnnotationID
    public var text: String
    public var fontSize: BeautifyMetric
    public var color: AnnotationColor
    /// How visible the mark is, on top of whatever alpha the colour carries.
    public var opacity: CGFloat
    /// Measured like every other angle here: from the positive x-axis, clockwise in the
    /// model's top-left space. A tiled watermark is conventionally run uphill, so the
    /// default leans the other way.
    public var rotationDegrees: CGFloat
    /// Whether the mark repeats across the picture or appears once.
    public var isTiled: Bool
    /// Gap between tiles, as a multiple of the text's own size. 1 means the tiles touch;
    /// larger is sparser.
    public var spacing: CGFloat
    /// Where a single mark sits. Ignored when tiled.
    public var placement: BeautifyAlignment

    public init(
        id: AnnotationID = AnnotationID(),
        text: String = "",
        fontSize: BeautifyMetric = .relative(0.05),
        color: AnnotationColor = .white,
        opacity: CGFloat = 0.35,
        rotationDegrees: CGFloat = -30,
        isTiled: Bool = false,
        spacing: CGFloat = 1.6,
        placement: BeautifyAlignment = .bottomTrailing
    ) {
        self.id = id
        self.text = text
        self.fontSize = fontSize
        self.color = color
        self.opacity = min(max(opacity, 0), 1)
        self.rotationDegrees = rotationDegrees
        self.isTiled = isTiled
        // Below 1 the tiles overlap into an unreadable smear; the cap keeps a stray large
        // value from producing a single mark in the middle of an empty picture.
        self.spacing = min(max(spacing, 1), 12)
        self.placement = placement
    }

    /// Whether this watermark would draw anything.
    public var isIdentity: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || opacity <= 0
            || fontSize.isZero
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, fontSize, color, opacity, rotationDegrees, isTiled, spacing, placement
    }

    /// Every field defaults, so a spec written by a later Kadr still opens (docs/08 §2.6).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decodeIfPresent(AnnotationID.self, forKey: .id) ?? AnnotationID(),
            text: container.decodeIfPresent(String.self, forKey: .text) ?? "",
            fontSize: container.decodeIfPresent(BeautifyMetric.self, forKey: .fontSize)
                ?? .relative(0.05),
            color: container.decodeIfPresent(AnnotationColor.self, forKey: .color) ?? .white,
            opacity: container.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 0.35,
            rotationDegrees: container.decodeIfPresent(CGFloat.self, forKey: .rotationDegrees) ?? -30,
            isTiled: container.decodeIfPresent(Bool.self, forKey: .isTiled) ?? false,
            spacing: container.decodeIfPresent(CGFloat.self, forKey: .spacing) ?? 1.6,
            placement: container.decodeIfPresent(BeautifyAlignment.self, forKey: .placement)
                ?? .bottomTrailing
        )
    }

    // MARK: - Presets

    /// One quiet mark in the corner.
    public static func signature(_ text: String) -> WatermarkSpec {
        WatermarkSpec(text: text, fontSize: .relative(0.035), opacity: 0.5, rotationDegrees: 0)
    }

    /// The repeated diagonal that survives a crop.
    public static func tiled(_ text: String) -> WatermarkSpec {
        WatermarkSpec(text: text, fontSize: .relative(0.05), opacity: 0.18, isTiled: true)
    }
}

/// Where each copy of a watermark goes (docs/09 U1.4).
///
/// Pure, and separate from the renderer, for the reason the rest of this milestone's
/// geometry is: it can be checked without drawing anything, and "does the tiling actually
/// cover the corners once it is rotated" is exactly the kind of thing that looks fine in a
/// preview and is wrong in the exported file.
public struct WatermarkLayout: Equatable, Sendable {
    /// One copy of the text: where its centre goes, and how far it is turned.
    public struct Placement: Equatable, Sendable {
        public var center: CGPoint
        public var rotationDegrees: CGFloat

        public init(center: CGPoint, rotationDegrees: CGFloat) {
            self.center = center
            self.rotationDegrees = rotationDegrees
        }
    }

    public var placements: [Placement]
    /// The size the text should be drawn at.
    public var fontSize: CGFloat

    /// The mark's positions over `rect`, given how big one copy of the text measures.
    ///
    /// - Parameter textSize: the rendered size of one copy, which only the renderer knows.
    public static func compute(
        _ spec: WatermarkSpec,
        in rect: CGRect,
        textSize: CGSize
    ) -> WatermarkLayout {
        let shortestEdge = max(min(rect.width, rect.height), 1)
        let fontSize = spec.fontSize.resolved(shortestEdge: shortestEdge)
        guard !spec.isIdentity, rect.width > 0, rect.height > 0 else {
            return WatermarkLayout(placements: [], fontSize: fontSize)
        }

        guard spec.isTiled else {
            return WatermarkLayout(
                placements: [Placement(
                    center: singlePlacement(spec, in: rect, textSize: textSize),
                    rotationDegrees: spec.rotationDegrees
                )],
                fontSize: fontSize
            )
        }
        return WatermarkLayout(
            placements: tiledPlacements(spec, in: rect, textSize: textSize),
            fontSize: fontSize
        )
    }

    /// One mark, inset from the edge it is aligned to by a margin proportional to itself.
    private static func singlePlacement(
        _ spec: WatermarkSpec,
        in rect: CGRect,
        textSize: CGSize
    ) -> CGPoint {
        let margin = max(textSize.height, 1) * 0.75
        let box = rect.insetBy(dx: margin + textSize.width / 2, dy: margin + textSize.height / 2)
        // A margin larger than the picture would invert the box; centring is the sane
        // answer for a mark too big to sit in a corner.
        guard box.width > 0, box.height > 0 else {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        return CGPoint(
            x: box.minX + box.width * spec.placement.horizontalBias,
            y: box.minY + box.height * spec.placement.verticalBias
        )
    }

    /// A rotated grid covering the whole rect.
    ///
    /// Laid out in the *rotated* frame and mapped back, rather than laid out upright and
    /// rotated: rotating a grid that exactly covers the rect leaves the corners bare,
    /// which is the one place a watermark most needs to be. The grid is therefore built
    /// over a square the size of the rect's diagonal, which covers it at any angle.
    private static func tiledPlacements(
        _ spec: WatermarkSpec,
        in rect: CGRect,
        textSize: CGSize
    ) -> [Placement] {
        let stepX = max(textSize.width, 1) * spec.spacing
        let stepY = max(textSize.height, 1) * spec.spacing * 1.4
        let reach = hypot(rect.width, rect.height) / 2
        let angle = spec.rotationDegrees * .pi / 180
        let centre = CGPoint(x: rect.midX, y: rect.midY)

        let columns = Int((reach * 2 / stepX).rounded(.up)) + 1
        let rows = Int((reach * 2 / stepY).rounded(.up)) + 1
        // A pathological spacing against a huge canvas could ask for millions of tiles;
        // the cap keeps a slider drag from wedging the renderer.
        guard columns * rows <= maximumTiles else {
            return [Placement(center: centre, rotationDegrees: spec.rotationDegrees)]
        }

        var placements: [Placement] = []
        placements.reserveCapacity(columns * rows)
        for row in 0 ..< rows {
            // Every other row is offset by half a step, so the tiling reads as a texture
            // rather than as a grid of columns.
            let offset = row.isMultiple(of: 2) ? 0 : stepX / 2
            for column in 0 ..< columns {
                let local = CGPoint(
                    x: -reach + CGFloat(column) * stepX + offset,
                    y: -reach + CGFloat(row) * stepY
                )
                placements.append(Placement(
                    center: CGPoint(
                        x: centre.x + local.x * cos(angle) - local.y * sin(angle),
                        y: centre.y + local.x * sin(angle) + local.y * cos(angle)
                    ),
                    rotationDegrees: spec.rotationDegrees
                ))
            }
        }
        return placements
    }

    /// Far more than any real watermark needs, and small enough to draw in a frame.
    static let maximumTiles = 4000
}
