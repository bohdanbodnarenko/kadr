import CoreGraphics
import Foundation

/// Where everything sits on a beautified canvas (docs/03 §3 P2, docs/09 U1.1).
///
/// A pure function of `contentSize + spec`, deliberately: layout is the part of beautify
/// that has to agree between the live canvas, the export renderer and any preview, and the
/// only way three call sites agree is if none of them does the arithmetic. It is also the
/// part worth golden-testing, which a function returning a value makes easy and a renderer
/// drawing into a context does not.
public struct BeautifyLayout: Equatable, Sendable {
    /// The whole exported canvas.
    public var canvasSize: CGSize
    /// The rounded, shadowed card the capture sits on.
    public var cardRect: CGRect
    /// Where the capture itself is drawn. Inset from the card by the border ring;
    /// identical to `cardRect` when there is no ring.
    public var imageRect: CGRect
    /// Per-corner radii of the card, already clamped to it.
    public var corners: BeautifyCorners
    /// Per-corner radii of the capture inside the ring.
    ///
    /// Smaller than the card's by the ring's thickness, which is what makes a border look
    /// like a mount rather than like two rounded rectangles that happen to be near each
    /// other: concentric curves need concentric radii.
    public var imageCorners: BeautifyCorners
    /// The canvas edges the card is pressed against.
    public var stuckEdges: BeautifyEdges

    public init(
        canvasSize: CGSize,
        cardRect: CGRect,
        imageRect: CGRect,
        corners: BeautifyCorners,
        imageCorners: BeautifyCorners? = nil,
        stuckEdges: BeautifyEdges = .none
    ) {
        self.canvasSize = canvasSize
        self.cardRect = cardRect
        self.imageRect = imageRect
        self.corners = corners
        self.imageCorners = imageCorners ?? corners
        self.stuckEdges = stuckEdges
    }

    /// The capture's frame, under the name the pre-U1.1 code used for it.
    public var contentRect: CGRect {
        imageRect
    }

    /// Lays a capture of `contentSize` onto a canvas.
    ///
    /// The order matters and is not arbitrary:
    ///
    /// 1. Lengths resolve against the *content's* shortest edge, not the canvas's — the
    ///    canvas is not known yet, and padding relative to a canvas that padding determines
    ///    would be circular.
    /// 2. Each edge gets its own inset, because a stuck edge gets none.
    /// 3. The aspect ratio grows the canvas; it never shrinks it, or a 16:9 preset would
    ///    crop a tall screenshot.
    /// 4. The card is placed inside the *inset box*, so alignment moves it within the
    ///    padding rather than through it — otherwise "bottom" and "bottom, stuck" would
    ///    render identically and the setting would do nothing.
    /// 5. A border ring grows the *card*, not the canvas around it. The capture keeps its
    ///    own size and the ring is added outside it, so turning a border on does not
    ///    shrink the screenshot.
    public static func compute(contentSize: CGSize, spec: BeautifySpec) -> BeautifyLayout {
        let capture = CGSize(width: max(contentSize.width, 1), height: max(contentSize.height, 1))
        let shortestEdge = min(capture.width, capture.height)
        let border = spec.border.thickness.resolved(shortestEdge: shortestEdge)
        // The card is what padding, alignment and the aspect ratio are measured against.
        let content = CGSize(width: capture.width + border * 2, height: capture.height + border * 2)

        let padding = spec.padding.resolved(shortestEdge: shortestEdge)
        let shadowOutset = spec.shadow.outset(shortestEdge: shortestEdge)
        // The shadow needs room even when padding is zero, or it is clipped at the canvas
        // edge and reads as a hard line.
        let inset = max(padding, shadowOutset)
        let stuck = spec.stuckEdges

        let insets = CGRect(
            x: stuck.contains(.leading) ? 0 : inset,
            y: stuck.contains(.top) ? 0 : inset,
            width: stuck.contains(.trailing) ? 0 : inset,
            height: stuck.contains(.bottom) ? 0 : inset
        )

        var canvasWidth = content.width + insets.minX + insets.width
        var canvasHeight = content.height + insets.minY + insets.height
        if let ratio = spec.aspect.ratio, ratio > 0 {
            let current = canvasWidth / canvasHeight
            if current < ratio {
                canvasWidth = canvasHeight * ratio
            } else if current > ratio {
                canvasHeight = canvasWidth / ratio
            }
        }

        // The region the card may occupy: the canvas less its insets.
        let box = CGRect(
            x: insets.minX,
            y: insets.minY,
            width: max(canvasWidth - insets.minX - insets.width, content.width),
            height: max(canvasHeight - insets.minY - insets.height, content.height)
        )
        let cardRect = CGRect(
            x: box.minX + (box.width - content.width) * spec.alignment.horizontalBias,
            y: box.minY + (box.height - content.height) * spec.alignment.verticalBias,
            width: content.width,
            height: content.height
        )

        let radius = spec.cornerRadius.resolved(shortestEdge: shortestEdge)
        let corners = BeautifyCorners.resolving(radius: radius, stuck: stuck).clamped(to: cardRect)
        let imageRect = cardRect.insetBy(dx: border, dy: border)
        return BeautifyLayout(
            canvasSize: CGSize(width: canvasWidth, height: canvasHeight),
            cardRect: cardRect,
            imageRect: imageRect,
            corners: corners,
            // Concentric: each inner radius is the outer one less the ring's thickness.
            imageCorners: corners.inset(by: border).clamped(to: imageRect),
            stuckEdges: stuck
        )
    }
}
