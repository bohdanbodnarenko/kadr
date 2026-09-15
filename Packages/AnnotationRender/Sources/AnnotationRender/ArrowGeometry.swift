import AnnotationModel
import CoreGraphics
import Foundation
import QuartzCore

/// Shaft and head paths for an arrow, shared by the canvas and the export (docs/16 ED-2).
///
/// One geometry so a filled head cannot look blunter on the canvas than in the PNG, and so
/// a start head is the same shape as an end head pointed the other way.
public struct ArrowGeometry {
    public struct Head {
        public var path: CGPath
        public var isFilled: Bool
    }

    public var shaft: CGPath
    public var startHead: Head?
    public var endHead: Head?

    public static func make(_ spec: ArrowSpec) -> ArrowGeometry {
        let chord = hypot(spec.end.x - spec.start.x, spec.end.y - spec.start.y)
        let length = headLength(chord: chord, width: spec.stroke.width)
        let startAngle = startTangent(spec)
        let endAngle = endTangent(spec)

        let startInset = inset(for: spec.startHead, length: length)
        let endInset = inset(for: spec.head, length: length)
        let shaftStart = insetPoint(spec.start, toward: startControl(spec), by: startInset)
        let shaftEnd = insetPoint(spec.end, toward: endControl(spec), by: endInset)

        let shaft = CGMutablePath()
        shaft.move(to: shaftStart)
        if let control = spec.controlPoint {
            shaft.addQuadCurve(to: shaftEnd, control: control)
        } else {
            shaft.addLine(to: shaftEnd)
        }

        return ArrowGeometry(
            shaft: shaft,
            startHead: spec.startHead.map { head($0, tip: spec.start, angle: startAngle + .pi, length: length) },
            endHead: head(spec.head, tip: spec.end, angle: endAngle, length: length)
        )
    }

    /// `clamp(chord/5, 1.5w, 4w)`, then a floor so a short stub still has a readable head.
    public static func headLength(chord: CGFloat, width: CGFloat) -> CGFloat {
        let clamped = min(max(chord / 5, width * 1.5), width * 4)
        return max(clamped, 8)
    }

    public static func inset(for style: ArrowHead?, length: CGFloat) -> CGFloat {
        switch style {
        case .none, .open, .bar: 0
        case .filled, .diamond: length
        case .concave: length * 0.65
        case .dot: length * 0.45
        }
    }

    static func startTangent(_ spec: ArrowSpec) -> CGFloat {
        let next = spec.controlPoint ?? spec.end
        return atan2(next.y - spec.start.y, next.x - spec.start.x)
    }

    static func endTangent(_ spec: ArrowSpec) -> CGFloat {
        let previous = spec.controlPoint ?? spec.start
        return atan2(spec.end.y - previous.y, spec.end.x - previous.x)
    }

    private static func startControl(_ spec: ArrowSpec) -> CGPoint {
        spec.controlPoint ?? spec.end
    }

    private static func endControl(_ spec: ArrowSpec) -> CGPoint {
        spec.controlPoint ?? spec.start
    }

    private static func insetPoint(_ tip: CGPoint, toward other: CGPoint, by distance: CGFloat) -> CGPoint {
        guard distance > 0 else { return tip }
        let dx = other.x - tip.x
        let dy = other.y - tip.y
        let span = hypot(dx, dy)
        guard span > 0.001 else { return tip }
        let fraction = min(distance / span, 0.9)
        return CGPoint(x: tip.x + dx * fraction, y: tip.y + dy * fraction)
    }

    private static func head(_ style: ArrowHead, tip: CGPoint, angle: CGFloat, length: CGFloat) -> Head {
        let spread = CGFloat.pi / 7
        let left = CGPoint(
            x: tip.x - length * cos(angle - spread),
            y: tip.y - length * sin(angle - spread)
        )
        let right = CGPoint(
            x: tip.x - length * cos(angle + spread),
            y: tip.y - length * sin(angle + spread)
        )
        switch style {
        case .filled:
            return closedHead([tip, left, right], filled: true)
        case .open:
            return openHead([left, tip, right])
        case .concave:
            let notch = CGPoint(
                x: tip.x - length * 0.65 * cos(angle),
                y: tip.y - length * 0.65 * sin(angle)
            )
            return closedHead([tip, left, notch, right], filled: true)
        case .dot:
            return dotHead(tip: tip, angle: angle, length: length)
        case .bar:
            return barHead(tip: tip, angle: angle, length: length)
        case .diamond:
            return diamondHead(tip: tip, angle: angle, length: length)
        }
    }

    private static func closedHead(_ points: [CGPoint], filled: Bool) -> Head {
        let path = CGMutablePath()
        guard let first = points.first else { return Head(path: path, isFilled: filled) }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return Head(path: path, isFilled: filled)
    }

    private static func openHead(_ points: [CGPoint]) -> Head {
        let path = CGMutablePath()
        guard let first = points.first else { return Head(path: path, isFilled: false) }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return Head(path: path, isFilled: false)
    }

    private static func dotHead(tip: CGPoint, angle: CGFloat, length: CGFloat) -> Head {
        let radius = length * 0.45
        let centre = CGPoint(x: tip.x - radius * cos(angle), y: tip.y - radius * sin(angle))
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        return Head(path: path, isFilled: true)
    }

    private static func barHead(tip: CGPoint, angle: CGFloat, length: CGFloat) -> Head {
        let half = length * 0.55
        let perp = angle + .pi / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: tip.x + half * cos(perp), y: tip.y + half * sin(perp)))
        path.addLine(to: CGPoint(x: tip.x - half * cos(perp), y: tip.y - half * sin(perp)))
        return Head(path: path, isFilled: false)
    }

    private static func diamondHead(tip: CGPoint, angle: CGFloat, length: CGFloat) -> Head {
        let back = CGPoint(x: tip.x - length * cos(angle), y: tip.y - length * sin(angle))
        let mid = CGPoint(x: (tip.x + back.x) / 2, y: (tip.y + back.y) / 2)
        let half = length * 0.35
        let perp = angle + .pi / 2
        return closedHead([
            tip,
            CGPoint(x: mid.x + half * cos(perp), y: mid.y + half * sin(perp)),
            back,
            CGPoint(x: mid.x - half * cos(perp), y: mid.y - half * sin(perp))
        ], filled: true)
    }
}

/// Editing-time arrow: a stroked shaft plus filled or stroked head sublayers (docs/16 ED-2).
public final class ArrowLayer: CALayer {
    let shaft = CAShapeLayer()
    let startHead = CAShapeLayer()
    let endHead = CAShapeLayer()

    override public init() {
        super.init()
        addSublayer(shaft)
        addSublayer(startHead)
        addSublayer(endHead)
        for layer in [shaft, startHead, endHead] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
        }
    }

    override public init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ spec: ArrowSpec) {
        let geometry = ArrowGeometry.make(spec)
        shaft.path = geometry.shaft
        shaft.strokeColor = spec.stroke.color.cgColor
        shaft.lineWidth = spec.stroke.width
        shaft.lineDashPattern = spec.stroke.dashPattern.isEmpty
            ? nil
            : spec.stroke.dashPattern.map { NSNumber(value: Double($0)) }
        shaft.fillColor = nil
        apply(geometry.startHead, to: startHead, stroke: spec.stroke)
        apply(geometry.endHead, to: endHead, stroke: spec.stroke)
    }

    private func apply(_ head: ArrowGeometry.Head?, to layer: CAShapeLayer, stroke: StrokeStyle) {
        guard let head else {
            layer.path = nil
            layer.isHidden = true
            return
        }
        layer.isHidden = false
        layer.path = head.path
        layer.strokeColor = stroke.color.cgColor
        layer.lineWidth = stroke.width
        layer.fillColor = head.isFilled ? stroke.color.cgColor : nil
    }
}
