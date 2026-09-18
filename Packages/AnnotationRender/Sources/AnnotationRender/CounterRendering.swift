import AnnotationModel
import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// How a counter badge is drawn, for the editor layer and the export (docs/03 §3).
///
/// One path because the live badge used to be a `CATextLayer` in a box shorter than its
/// font: the disc resized during a drag and the digits caught up on mouse-up, and the
/// bottoms of 3, 5, 8 were clipped. Both surfaces now fill the circle and optically centre
/// the glyphs.
enum CounterRendering {
    /// Helvetica Bold matches the original badges; a document should not change typeface
    /// because the renderer was rewritten.
    static let fontName = "Helvetica-Bold"

    static func frame(_ spec: CounterSpec) -> CGRect {
        CGRect(
            x: spec.center.x - spec.radius,
            y: spec.center.y - spec.radius,
            width: spec.radius * 2,
            height: spec.radius * 2
        )
    }

    /// Fraction of the diameter. More digits get a smaller face so "10" and "VIII" stay
    /// inside the disc instead of being clipped to it.
    static func fontSize(for spec: CounterSpec) -> CGFloat {
        let digits = max(spec.label.count, 1)
        let fraction: CGFloat = if digits <= 2 {
            0.54
        } else if digits == 3 {
            0.44
        } else {
            0.34
        }
        return spec.radius * 2 * fraction
    }

    /// Draws the disc and digits in a **y-down** context, matching the flipped export
    /// canvas and the editor view.
    static func draw(_ spec: CounterSpec, in context: CGContext) {
        let rect = frame(spec)
        context.setFillColor(spec.fill.cgColor)
        context.fillEllipse(in: rect)

        let font = CTFontCreateWithName(fontName as CFString, fontSize(for: spec), nil)
        let attributed = NSAttributedString(string: spec.label, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): spec.textColor.cgColor
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        // CoreText draws y-up. Undo the canvas flip around the badge's centre so the
        // optical box lands in the middle of the disc, not on its typographic baseline.
        context.saveGState()
        context.translateBy(x: 0, y: spec.center.y * 2)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(
            x: spec.center.x - bounds.width / 2 - bounds.minX,
            y: spec.center.y - bounds.height / 2 - bounds.minY
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Editing-time badge: redraws the digits whenever the radius changes, so a resize does
/// not leave a stale number sitting on a growing disc.
///
/// And only then — or when the number, the colours or the density change. Dragging a badge
/// is a pure translation, and redrawing CoreText for it on every mouse-move was waste.
public final class CounterBadgeLayer: CALayer {
    private var spec: CounterSpec?
    /// What the backing store currently shows, or nil before the first draw.
    private var drawnKey: DrawKey?
    /// Redraws so far. Internal, for the tests that pin the early return.
    private(set) var displayCount = 0

    /// The spec with its position taken out, plus the size and density it is drawn at.
    struct DrawKey: Equatable {
        var spec: CounterSpec
        var size: CGSize
        var scale: CGFloat

        init(spec: CounterSpec, size: CGSize, scale: CGFloat) {
            var normalized = spec
            normalized.center = .zero
            self.spec = normalized
            self.size = size
            self.scale = scale
        }
    }

    override public init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override public init(layer: Any) {
        spec = (layer as? CounterBadgeLayer)?.spec
        super.init(layer: layer)
        needsDisplayOnBoundsChange = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ spec: CounterSpec) {
        self.spec = spec
        frame = CounterRendering.frame(spec)
        let key = DrawKey(spec: spec, size: bounds.size, scale: contentsScale)
        guard key != drawnKey || needsDisplay() else { return }
        setNeedsDisplay()
        displayIfNeeded()
    }

    override public func display() {
        if let spec {
            drawnKey = DrawKey(spec: spec, size: bounds.size, scale: contentsScale)
        }
        displayCount += 1
        super.display()
    }

    override public func draw(in ctx: CGContext) {
        guard let spec else { return }
        // The editor canvas is flipped (y-down), and `draw(in:)` inherits that. Do not
        // flip again here — that is what stood the digits on their heads. Export already
        // flips its canvas once, then both paths share `CounterRendering.draw`.
        var local = spec
        local.center = CGPoint(x: bounds.midX, y: bounds.midY)
        CounterRendering.draw(local, in: ctx)
    }
}
