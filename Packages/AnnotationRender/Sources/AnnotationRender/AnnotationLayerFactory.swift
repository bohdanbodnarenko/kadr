import AnnotationModel
import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import Shared

/// Builds the editing-time layer tree (docs/04 §6).
///
/// One layer per annotation, so dragging an object mutates exactly one layer's path and
/// nothing else in the tree is touched — that is what holds 60 fps on a 5K capture
/// (docs/03 §3). The export path is a separate renderer on purpose: an export must never
/// be a snapshot of whatever the view happened to look like.
public enum AnnotationLayerFactory {
    /// Makes the layer for one annotation, or `nil` for commands that draw nothing at
    /// editing time.
    /// - Parameter imageScale: the base image's pixels per point, which the
    ///   measurement readout and the live redaction preview both need.
    /// - Parameter baseImage: the capture's pixels, so a blur samples what is
    ///   actually under the box rather than drawing a grey stand-in.
    public static func makeLayer(
        for command: AnnotationCommand,
        contentsScale: CGFloat,
        imageScale: CGFloat = 1,
        baseImage: CGImage? = nil
    ) -> CALayer? {
        let layer = strokeShapeLayer(for: command)
            ?? contentLayer(
                for: command,
                contentsScale: contentsScale,
                imageScale: imageScale,
                baseImage: baseImage
            )
        layer?.contentsScale = contentsScale
        layer?.name = command.id.rawValue.uuidString
        return layer
    }

    /// The annotations that are one stroked path.
    private static func strokeShapeLayer(for command: AnnotationCommand) -> CALayer? {
        switch command {
        case let .arrow(spec): arrowLayer(spec)
        case let .shape(spec): shapeLayer(spec)
        case let .line(spec): lineLayer(spec)
        case let .freehand(spec): strokeLayer(spec.points, stroke: spec.stroke)
        case let .highlighter(spec): highlighterLayer(spec)
        default: nil
        }
    }

    /// The annotations that carry text or an effect, and the chrome that draws nothing.
    private static func contentLayer(
        for command: AnnotationCommand,
        contentsScale: CGFloat,
        imageScale: CGFloat,
        baseImage: CGImage?
    ) -> CALayer? {
        switch command {
        case let .text(spec): textLayer(spec, contentsScale: contentsScale)
        case let .counter(spec): counterLayer(spec, contentsScale: contentsScale)
        case let .redaction(spec): redactionPreviewLayer(spec, baseImage: baseImage, imageScale: imageScale)
        case let .measure(spec): measureLayer(spec, contentsScale: contentsScale, imageScale: imageScale)
        case let .image(spec): imageLayer(spec)
        // The crop and the beautify backdrop are chrome around the canvas, not objects
        // on it, so they have no layer of their own here.
        default: nil
        }
    }

    /// Updates an existing layer in place.
    ///
    /// The hot path during a drag *and* during inspector style edits: no allocation, no
    /// tree surgery — path, stroke and fill all land on a layer that is already on screen.
    public static func update(
        _ layer: CALayer,
        for command: AnnotationCommand,
        imageScale: CGFloat = 1,
        baseImage: CGImage? = nil
    ) {
        switch command {
        case let .arrow(spec):
            applyArrow(spec, to: layer)
        case let .shape(spec):
            applyShape(spec, to: layer)
        case let .line(spec):
            applyLine(spec, to: layer)
        case let .freehand(spec):
            applyStrokePath(spec.points, stroke: spec.stroke, to: layer)
        case let .highlighter(spec):
            applyStrokePath(spec.points, stroke: spec.stroke, to: layer)
        default:
            updateContentLayer(layer, for: command, imageScale: imageScale, baseImage: baseImage)
        }
    }

    /// The layers that carry text, an effect or an image rather than one stroked path.
    private static func updateContentLayer(
        _ layer: CALayer,
        for command: AnnotationCommand,
        imageScale: CGFloat,
        baseImage: CGImage?
    ) {
        switch command {
        case let .text(spec):
            layer.frame = spec.rect
            (layer as? CATextLayer)?.string = attributedText(spec)
        case let .counter(spec):
            layer.frame = counterFrame(spec)
        case let .redaction(spec):
            applyRedactionPreview(to: layer, spec: spec, baseImage: baseImage, imageScale: imageScale)
        case let .measure(spec):
            updateMeasureLayer(layer, spec: spec, imageScale: imageScale)
        case let .image(spec):
            updateImageLayer(layer, spec: spec)
        default:
            // Crop, beautify and background removal are the canvas, not layers on it.
            break
        }
    }

    // MARK: - Paths

    static func arrowPath(_ spec: ArrowSpec) -> CGPath {
        let path = CGMutablePath()
        path.move(to: spec.start)
        if let control = spec.controlPoint {
            path.addQuadCurve(to: spec.end, control: control)
        } else {
            path.addLine(to: spec.end)
        }

        // The head is part of the same path, so one layer draws the whole arrow.
        let approach = spec.controlPoint ?? spec.start
        let angle = atan2(spec.end.y - approach.y, spec.end.x - approach.x)
        let length = max(spec.stroke.width * 3.5, 12)
        let spread = CGFloat.pi / 7
        path.move(to: CGPoint(
            x: spec.end.x - length * cos(angle - spread),
            y: spec.end.y - length * sin(angle - spread)
        ))
        path.addLine(to: spec.end)
        path.addLine(to: CGPoint(
            x: spec.end.x - length * cos(angle + spread),
            y: spec.end.y - length * sin(angle + spread)
        ))
        return path
    }

    static func shapePath(_ spec: ShapeSpec) -> CGPath {
        let rect = spec.rect.standardized
        return switch spec.kind {
        case .rectangle:
            CGPath(rect: rect, transform: nil)
        case let .roundedRectangle(cornerRadius):
            CGPath(
                roundedRect: rect,
                cornerWidth: min(cornerRadius, min(rect.width, rect.height) / 2),
                cornerHeight: min(cornerRadius, min(rect.width, rect.height) / 2),
                transform: nil
            )
        case .ellipse:
            CGPath(ellipseIn: rect, transform: nil)
        }
    }

    static func linePath(_ spec: LineSpec) -> CGPath {
        let path = CGMutablePath()
        path.move(to: spec.start)
        path.addLine(to: spec.end)
        return path
    }

    static func strokePath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    // MARK: - Layers

    private static func styled(_ path: CGPath, stroke: StrokeStyle, fill: FillStyle = .none) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        apply(stroke: stroke, fill: fill, to: layer)
        return layer
    }

    private static func apply(stroke: StrokeStyle, fill: FillStyle = .none, to layer: CAShapeLayer) {
        layer.strokeColor = stroke.color.cgColor
        layer.lineWidth = stroke.width
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.fillColor = fill.color?.cgColor
        layer.lineDashPattern = stroke.dashPattern.isEmpty
            ? nil
            : stroke.dashPattern.map { NSNumber(value: Double($0)) }
    }

    private static func applyArrow(_ spec: ArrowSpec, to layer: CALayer) {
        guard let shape = layer as? CAShapeLayer else { return }
        shape.path = arrowPath(spec)
        apply(stroke: spec.stroke, to: shape)
        shape.fillColor = spec.head == .open ? nil : spec.stroke.color.cgColor
    }

    private static func applyShape(_ spec: ShapeSpec, to layer: CALayer) {
        guard let shape = layer as? CAShapeLayer else { return }
        shape.path = shapePath(spec)
        apply(stroke: spec.stroke, fill: spec.fill, to: shape)
    }

    private static func applyLine(_ spec: LineSpec, to layer: CALayer) {
        guard let shape = layer as? CAShapeLayer else { return }
        shape.path = linePath(spec)
        apply(stroke: spec.stroke, to: shape)
    }

    private static func applyStrokePath(_ points: [CGPoint], stroke: StrokeStyle, to layer: CALayer) {
        guard let shape = layer as? CAShapeLayer else { return }
        shape.path = strokePath(points)
        apply(stroke: stroke, to: shape)
    }

    private static func arrowLayer(_ spec: ArrowSpec) -> CAShapeLayer {
        let layer = styled(arrowPath(spec), stroke: spec.stroke)
        // A filled head needs the path filled; an open one must not be.
        layer.fillColor = spec.head == .open ? nil : spec.stroke.color.cgColor
        return layer
    }

    private static func shapeLayer(_ spec: ShapeSpec) -> CAShapeLayer {
        styled(shapePath(spec), stroke: spec.stroke, fill: spec.fill)
    }

    private static func lineLayer(_ spec: LineSpec) -> CAShapeLayer {
        styled(linePath(spec), stroke: spec.stroke)
    }

    private static func strokeLayer(_ points: [CGPoint], stroke: StrokeStyle) -> CAShapeLayer {
        styled(strokePath(points), stroke: stroke)
    }

    private static func highlighterLayer(_ spec: HighlighterSpec) -> CAShapeLayer {
        let layer = styled(strokePath(spec.points), stroke: spec.stroke)
        // Multiply, so highlighted text stays readable underneath (docs/03 §3).
        layer.compositingFilter = "multiplyBlendMode"
        return layer
    }

    private static func textLayer(_ spec: TextSpec, contentsScale: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        layer.frame = spec.rect
        layer.string = attributedText(spec)
        layer.isWrapped = true
        layer.truncationMode = .none
        layer.contentsScale = contentsScale
        if let background = spec.style.backgroundColor {
            layer.backgroundColor = background.cgColor
            layer.cornerRadius = 6
        }
        return layer
    }

    private static func attributedText(_ spec: TextSpec) -> NSAttributedString {
        let font = CTFontCreateWithName(spec.style.fontName as CFString, spec.style.fontSize, nil)
        return NSAttributedString(string: spec.string, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): spec.style.color.cgColor
        ])
    }

    private static func counterFrame(_ spec: CounterSpec) -> CGRect {
        CGRect(
            x: spec.center.x - spec.radius,
            y: spec.center.y - spec.radius,
            width: spec.radius * 2,
            height: spec.radius * 2
        )
    }

    private static func counterLayer(_ spec: CounterSpec, contentsScale: CGFloat) -> CALayer {
        let container = CALayer()
        container.frame = counterFrame(spec)
        container.backgroundColor = spec.fill.cgColor
        container.cornerRadius = spec.radius

        let text = CATextLayer()
        text.frame = CGRect(x: 0, y: spec.radius * 0.35, width: spec.radius * 2, height: spec.radius)
        text.string = NSAttributedString(string: "\(spec.number)", attributes: [
            .init(kCTFontAttributeName as String):
                CTFontCreateWithName("Helvetica-Bold" as CFString, spec.radius * 1.1, nil),
            .init(kCTForegroundColorAttributeName as String): spec.textColor.cgColor
        ])
        text.alignmentMode = .center
        text.contentsScale = contentsScale
        container.addSublayer(text)
        return container
    }

    /// Samples the capture under the box so the editor shows a real blur, not a grey
    /// stand-in (Screendrop's live redaction). Export still burns the effect in.
    private static func redactionPreviewLayer(
        _ spec: RedactionSpec,
        baseImage: CGImage?,
        imageScale: CGFloat
    ) -> CALayer {
        let layer = CALayer()
        applyRedactionPreview(to: layer, spec: spec, baseImage: baseImage, imageScale: imageScale)
        return layer
    }

    private static func applyRedactionPreview(
        to layer: CALayer,
        spec: RedactionSpec,
        baseImage: CGImage?,
        imageScale: CGFloat
    ) {
        layer.frame = spec.rect.standardized
        layer.masksToBounds = true
        layer.contentsGravity = .resize
        layer.borderWidth = 0
        if let baseImage, let preview = RedactionRasterizer().preview(spec, from: baseImage, scale: imageScale) {
            layer.contents = preview
            layer.backgroundColor = nil
            return
        }
        // Tests and a failed sample still need a visible region.
        layer.contents = nil
        layer.backgroundColor = CGColor(gray: 0.45, alpha: 0.55)
    }
}
