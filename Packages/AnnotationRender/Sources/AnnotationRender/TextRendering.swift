import AnnotationModel
import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// Text as the canvas and the export both draw it (docs/16 ED-1).
///
/// One path on top of `TextLayout`, so a bold centred pill cannot look different in the
/// editor than in the PNG, and so a second line grows the box instead of clipping.
public enum TextRendering {
    /// The box the layer occupies, including the pill when there is one.
    public static func frame(_ spec: TextSpec) -> CGRect {
        TextLayout.pillRect(spec) ?? spec.rect
    }

    /// Grows (or wraps) the spec so the stored rect matches the laid-out text.
    ///
    /// The alignment anchor stays put: centred text expands both ways, trailing text
    /// grows to the left, leading text grows to the right. Height always grows down.
    public static func fitted(_ spec: TextSpec) -> TextSpec {
        var spec = spec
        let maxWidth: CGFloat = spec.autoWidth ? 10000 : max(spec.rect.width, 1)
        let size = TextLayout.measuredSize(spec, maxWidth: maxWidth)
        let width = spec.autoWidth ? max(size.width, 24) : spec.rect.width
        let height = max(size.height, ceil(spec.style.fontSize * 1.2))
        var origin = spec.rect.origin
        if spec.autoWidth {
            let delta = width - spec.rect.width
            switch spec.style.alignment {
            case .leading: break
            case .center: origin.x -= delta / 2
            case .trailing: origin.x -= delta
            }
        }
        spec.rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        return spec
    }

    /// Draws the pill and the glyphs in a y-down context, matching the flipped canvas.
    public static func draw(_ spec: TextSpec, in context: CGContext) {
        guard !spec.string.isEmpty else { return }

        if let background = spec.style.backgroundColor, let pill = TextLayout.pillRect(spec) {
            let radius = TextLayout.pillRadius(for: spec.style)
            context.setFillColor(background.cgColor)
            context.addPath(CGPath(
                roundedRect: pill,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
            context.fillPath()
        }

        let framesetter = CTFramesetterCreateWithAttributedString(TextLayout.attributedString(spec))
        let path = CGPath(rect: spec.rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        context.saveGState()
        context.translateBy(x: 0, y: spec.rect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

/// Editing-time text: `draw(in:)` calls the same code the export uses (docs/16 ED-1).
public final class TextBadgeLayer: CALayer {
    private var spec: TextSpec?

    override public init() {
        super.init()
        needsDisplayOnBoundsChange = true
        masksToBounds = false
    }

    override public init(layer: Any) {
        spec = (layer as? TextBadgeLayer)?.spec
        super.init(layer: layer)
        needsDisplayOnBoundsChange = true
        masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ spec: TextSpec) {
        self.spec = spec
        let frame = TextRendering.frame(spec)
        self.frame = frame
        setNeedsDisplay()
        displayIfNeeded()
    }

    override public func draw(in ctx: CGContext) {
        guard let spec else { return }
        var local = spec
        local.rect = spec.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        TextRendering.draw(local, in: ctx)
    }
}
