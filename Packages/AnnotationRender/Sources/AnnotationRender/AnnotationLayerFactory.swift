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
        baseImage: CGImage? = nil,
        canvasRect: CGRect? = nil
    ) -> CALayer? {
        makeLayer(
            for: command,
            contentsScale: contentsScale,
            context: AnnotationLayerContext(imageScale: imageScale, baseImage: baseImage, canvasRect: canvasRect)
        )
    }

    /// Makes the layer for one annotation, with everything the canvas knows about where
    /// its pixels and previews come from.
    public static func makeLayer(
        for command: AnnotationCommand,
        contentsScale: CGFloat,
        context: AnnotationLayerContext
    ) -> CALayer? {
        let layer = strokeShapeLayer(for: command)
            ?? contentLayer(for: command, contentsScale: contentsScale, context: context)
        layer?.contentsScale = contentsScale
        layer?.name = command.id.rawValue.uuidString
        if let layer {
            applyRotation(of: command, to: layer)
        }
        return layer
    }

    /// Turns the layer about the annotation's own pivot (docs/16 ED-10).
    ///
    /// A layer's `transform` turns it about its `position`. That is the right point only
    /// for layers framed to their own rect; a stroked shape is a zero-sized layer at the
    /// canvas origin with its path in canvas coordinates, so a plain rotation swung a
    /// rectangle around the corner of the image while its selection frame — which turns
    /// about the shape's centre — stayed put. The transform is therefore built around
    /// `AnnotationHitTesting.rotationPivot`, the same point hit-testing, the outline and
    /// the export use, whatever the layer's frame.
    static func applyRotation(of command: AnnotationCommand, to layer: CALayer) {
        let radians = command.rotation
        guard radians != 0 else {
            layer.transform = CATransform3DIdentity
            return
        }
        let pivot = AnnotationHitTesting.rotationPivot(of: command)
        let offset = CGPoint(x: pivot.x - layer.position.x, y: pivot.y - layer.position.y)
        var transform = CATransform3DMakeTranslation(-offset.x, -offset.y, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(radians, 0, 0, 1))
        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(offset.x, offset.y, 0))
        layer.transform = transform
    }

    /// The annotations that are one stroked path.
    private static func strokeShapeLayer(for command: AnnotationCommand) -> CALayer? {
        switch command {
        case let .arrow(spec): arrowLayer(spec)
        case let .shape(spec): shapeLayer(spec)
        case let .line(spec): lineLayer(spec)
        case let .freehand(spec):
            strokeLayer(spec.isSmoothed ? StrokeSmoothing.smoothed(spec.points) : spec.points, stroke: spec.stroke)
        case let .highlighter(spec): highlighterLayer(spec)
        default: nil
        }
    }

    /// The annotations that carry text or an effect, and the chrome that draws nothing.
    private static func contentLayer(
        for command: AnnotationCommand,
        contentsScale: CGFloat,
        context: AnnotationLayerContext
    ) -> CALayer? {
        switch command {
        case let .text(spec): textLayer(spec, contentsScale: contentsScale)
        case let .counter(spec): counterLayer(spec, contentsScale: contentsScale)
        case let .redaction(spec): redactionPreviewLayer(spec, context: context)
        case let .spotlight(spec):
            spotlightLayer(spec, canvasRect: resolvedCanvas(context))
        case let .measure(spec): measureLayer(spec, contentsScale: contentsScale, imageScale: context.imageScale)
        case let .image(spec): imageLayer(spec)
        // The crop and the beautify backdrop are chrome around the canvas, not objects
        // on it, so they have no layer of their own here.
        default: nil
        }
    }

    private static func resolvedCanvas(_ context: AnnotationLayerContext) -> CGRect {
        resolvedCanvas(context.canvasRect, baseImage: context.baseImage, imageScale: context.imageScale)
    }

    /// Updates an existing layer in place.
    ///
    /// The hot path during a drag *and* during inspector style edits: no allocation, no
    /// tree surgery — path, stroke and fill all land on a layer that is already on screen.
    public static func update(
        _ layer: CALayer,
        for command: AnnotationCommand,
        imageScale: CGFloat = 1,
        baseImage: CGImage? = nil,
        canvasRect: CGRect? = nil
    ) {
        update(
            layer,
            for: command,
            context: AnnotationLayerContext(imageScale: imageScale, baseImage: baseImage, canvasRect: canvasRect)
        )
    }

    /// Updates an existing layer in place, with the canvas's full context.
    public static func update(_ layer: CALayer, for command: AnnotationCommand, context: AnnotationLayerContext) {
        // Geometry first, on an unturned layer: setting `frame` while a rotation is applied
        // is undefined in Core Animation, and moved a rotated text box or image sideways.
        if !CATransform3DIsIdentity(layer.transform) {
            layer.transform = CATransform3DIdentity
        }
        switch command {
        case let .arrow(spec):
            applyArrow(spec, to: layer)
        case let .shape(spec):
            applyShape(spec, to: layer)
        case let .line(spec):
            applyLine(spec, to: layer)
        case let .freehand(spec):
            applyStrokePath(
                spec.isSmoothed ? StrokeSmoothing.smoothed(spec.points) : spec.points,
                stroke: spec.stroke,
                to: layer
            )
        case let .highlighter(spec):
            applyStrokePath(spec.points, stroke: spec.stroke, to: layer)
        default:
            updateContentLayer(layer, for: command, context: context)
        }
        applyRotation(of: command, to: layer)
    }

    /// The layers that carry text, an effect or an image rather than one stroked path.
    private static func updateContentLayer(
        _ layer: CALayer,
        for command: AnnotationCommand,
        context: AnnotationLayerContext
    ) {
        switch command {
        case let .text(spec):
            if let badge = layer as? TextBadgeLayer {
                badge.apply(spec)
            } else {
                layer.frame = TextRendering.frame(spec)
            }
        case let .counter(spec):
            applyCounter(spec, to: layer)
        case let .redaction(spec):
            applyRedactionPreview(to: layer, spec: spec, context: context)
        case let .spotlight(spec):
            applySpotlight(to: layer, spec: spec, canvasRect: resolvedCanvas(context))
        case let .measure(spec):
            updateMeasureLayer(layer, spec: spec, imageScale: context.imageScale)
        case let .image(spec):
            updateImageLayer(layer, spec: spec)
        default:
            // Crop, beautify and background removal are the canvas, not layers on it.
            break
        }
    }

    // MARK: - Paths

    static func arrowPath(_ spec: ArrowSpec) -> CGPath {
        ArrowGeometry.make(spec).shaft
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
        if let arrow = layer as? ArrowLayer {
            arrow.apply(spec)
            return
        }
        guard let shape = layer as? CAShapeLayer else { return }
        shape.path = arrowPath(spec)
        apply(stroke: spec.stroke, to: shape)
        shape.fillColor = nil
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

    private static func arrowLayer(_ spec: ArrowSpec) -> ArrowLayer {
        let layer = ArrowLayer()
        layer.apply(spec)
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

    private static func textLayer(_ spec: TextSpec, contentsScale: CGFloat) -> CALayer {
        let layer = TextBadgeLayer()
        layer.contentsScale = contentsScale
        layer.apply(spec)
        return layer
    }

    private static func counterLayer(_ spec: CounterSpec, contentsScale: CGFloat) -> CALayer {
        let layer = CounterBadgeLayer()
        layer.contentsScale = contentsScale
        layer.apply(spec)
        return layer
    }

    private static func applyCounter(_ spec: CounterSpec, to layer: CALayer) {
        if let badge = layer as? CounterBadgeLayer {
            badge.apply(spec)
            return
        }
        layer.frame = CounterRendering.frame(spec)
    }
}
