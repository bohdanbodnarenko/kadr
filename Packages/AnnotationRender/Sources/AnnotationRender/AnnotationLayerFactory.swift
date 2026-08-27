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
    public static func makeLayer(for command: AnnotationCommand, contentsScale: CGFloat) -> CALayer? {
        let layer: CALayer? = switch command {
        case let .arrow(spec): arrowLayer(spec)
        case let .shape(spec): shapeLayer(spec)
        case let .line(spec): lineLayer(spec)
        case let .freehand(spec): strokeLayer(spec.points, stroke: spec.stroke)
        case let .highlighter(spec): highlighterLayer(spec)
        case let .text(spec): textLayer(spec, contentsScale: contentsScale)
        case let .counter(spec): counterLayer(spec, contentsScale: contentsScale)
        // Shown live as a preview rather than a burned-in effect, so the user can move it
        // freely; the export renderer is what makes it permanent.
        case let .redaction(spec): redactionPreviewLayer(spec)
        // The crop is chrome around the canvas, not an object on it.
        case .crop: nil
        }
        layer?.contentsScale = contentsScale
        layer?.name = command.id.rawValue.uuidString
        return layer
    }

    /// Updates an existing layer in place.
    ///
    /// The hot path during a drag: no allocation, no tree surgery, just new geometry on a
    /// layer that is already on screen.
    public static func update(_ layer: CALayer, for command: AnnotationCommand) {
        switch command {
        case let .arrow(spec):
            (layer as? CAShapeLayer)?.path = arrowPath(spec)
        case let .shape(spec):
            (layer as? CAShapeLayer)?.path = shapePath(spec)
        case let .line(spec):
            (layer as? CAShapeLayer)?.path = linePath(spec)
        case let .freehand(spec):
            (layer as? CAShapeLayer)?.path = strokePath(spec.points)
        case let .highlighter(spec):
            (layer as? CAShapeLayer)?.path = strokePath(spec.points)
        case let .text(spec):
            layer.frame = spec.rect
            (layer as? CATextLayer)?.string = attributedText(spec)
        case let .counter(spec):
            layer.frame = counterFrame(spec)
        case let .redaction(spec):
            layer.frame = spec.rect
        case .crop:
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
        layer.strokeColor = stroke.color.cgColor
        layer.lineWidth = stroke.width
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.fillColor = fill.color?.cgColor
        if !stroke.dashPattern.isEmpty {
            layer.lineDashPattern = stroke.dashPattern.map { NSNumber(value: Double($0)) }
        }
        return layer
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

    /// A live stand-in while editing: a frosted rectangle rather than a real blur, because
    /// re-running CoreImage on every drag frame would not hold 60 fps. The export renderer
    /// does the real work.
    private static func redactionPreviewLayer(_ spec: RedactionSpec) -> CALayer {
        let layer = CALayer()
        layer.frame = spec.rect
        layer.backgroundColor = CGColor(gray: 0.5, alpha: 0.85)
        layer.borderColor = CGColor(gray: 0.3, alpha: 1)
        layer.borderWidth = 1
        if case .pixelate = spec.style {
            layer.backgroundColor = CGColor(gray: 0.45, alpha: 0.9)
        }
        return layer
    }
}
