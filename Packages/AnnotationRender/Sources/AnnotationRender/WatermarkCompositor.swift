import AnnotationModel
import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// Draws a watermark over the finished canvas (docs/09 U1.4).
///
/// Last of everything, deliberately. A watermark that the perspective camera could tilt or
/// the progressive blur could soften would be a watermark someone can remove by turning
/// those off — the mark belongs to the exported file, not to the picture inside it.
enum WatermarkCompositor {
    /// The font every watermark uses.
    ///
    /// One face rather than a choice: a watermark is a mark, not typography, and the
    /// inspector has enough knobs. Bold because a translucent mark in a regular weight
    /// disappears against a busy screenshot.
    static let fontName = "Helvetica-Bold"

    /// Draws `spec` over `rect`, in a context already flipped to the model's top-left
    /// space like every other command.
    static func draw(_ spec: WatermarkSpec, in rect: CGRect, context: CGContext) {
        guard !spec.isIdentity else { return }

        let shortestEdge = max(min(rect.width, rect.height), 1)
        let fontSize = spec.fontSize.resolved(shortestEdge: shortestEdge)
        guard fontSize > 0 else { return }

        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: spec.text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): spec.color.cgColor
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let layout = WatermarkLayout.compute(
            spec,
            in: rect,
            textSize: CGSize(width: bounds.width, height: bounds.height)
        )
        guard !layout.placements.isEmpty else { return }

        context.saveGState()
        context.setAlpha(spec.opacity)
        // Clipped to the canvas: a tiled grid is deliberately larger than the picture so
        // its corners are covered, and the overspill must not reach a caller's context.
        context.clip(to: rect)

        for placement in layout.placements {
            context.saveGState()
            // Text draws in CoreGraphics' own orientation, so the canvas flip is undone
            // around each mark — the same dance every other text command does.
            context.translateBy(x: placement.center.x, y: placement.center.y)
            context.scaleBy(x: 1, y: -1)
            context.rotate(by: -placement.rotationDegrees * .pi / 180)
            context.textPosition = CGPoint(
                x: -bounds.width / 2 - bounds.minX,
                y: -bounds.height / 2 - bounds.minY
            )
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// Stamps a watermark onto an already-rendered canvas, after scene blur (docs/16 ED-3).
    static func stamp(
        _ spec: WatermarkSpec,
        onto image: CGImage,
        canvas: CGRect,
        scale: CGFloat
    ) -> CGImage? {
        guard let context = AnnotationExportRenderer.makeContext(
            width: image.width,
            height: image.height,
            matching: image
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        draw(spec, in: CGRect(origin: .zero, size: canvas.size), context: context)
        return context.makeImage()
    }
}

/// Editing-time watermark, rasterised with the same compositor the export uses (docs/16 ED-3).
///
/// The backing store is the size of the whole canvas, so redrawing it is the expensive part
/// of any document change. It is redrawn only when what it shows — the spec, the size or the
/// density — actually changed, and a canvas without a watermark holds no bitmap at all.
public final class WatermarkLayer: CALayer {
    private var spec: WatermarkSpec?
    /// What the backing store currently holds, or nil when it holds nothing.
    private var drawnKey: DrawKey?
    /// Redraws so far. Internal, for the tests that pin the early return.
    private(set) var displayCount = 0

    struct DrawKey: Equatable {
        var spec: WatermarkSpec
        var size: CGSize
        var scale: CGFloat
    }

    override public init() {
        super.init()
        needsDisplayOnBoundsChange = true
        contentsGravity = .resize
    }

    override public init(layer: Any) {
        spec = (layer as? WatermarkLayer)?.spec
        super.init(layer: layer)
        needsDisplayOnBoundsChange = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The spec worth drawing, or nil when there is nothing to show.
    private static func visible(_ spec: WatermarkSpec?) -> WatermarkSpec? {
        guard let spec, !spec.isIdentity else { return nil }
        return spec
    }

    private var currentKey: DrawKey? {
        guard let spec = Self.visible(spec), bounds.width > 0, bounds.height > 0 else { return nil }
        return DrawKey(spec: spec, size: bounds.size, scale: contentsScale)
    }

    public func apply(_ spec: WatermarkSpec?) {
        self.spec = spec
        guard let key = currentKey else {
            // Nothing to draw: give the canvas-sized bitmap back rather than keeping a
            // transparent one alive for the rest of the session.
            isHidden = true
            drawnKey = nil
            contents = nil
            return
        }
        isHidden = false
        guard key != drawnKey || contents == nil else { return }
        setNeedsDisplay()
        displayIfNeeded()
    }

    override public func display() {
        guard let key = currentKey else {
            drawnKey = nil
            contents = nil
            return
        }
        drawnKey = key
        displayCount += 1
        super.display()
    }

    override public func draw(in ctx: CGContext) {
        guard let spec, !spec.isIdentity, bounds.width > 0, bounds.height > 0 else { return }
        WatermarkCompositor.draw(spec, in: bounds, context: ctx)
    }
}
