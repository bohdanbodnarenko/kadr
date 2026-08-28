import AppKit
import Shared

/// The pixel ruler along the selection's edges (docs/03 §3 P3, docs/06 M21).
///
/// Precision mode already gives crosshair guides and a size badge; the ruler is what
/// turns "how big is it" into "how far along is that". Ticks are laid out in **pixels**,
/// not points, because the number a developer is checking against is the pixel one — on a
/// Retina display a 10-point tick spacing would silently mean 20 px.
@MainActor
final class RulerLayerGroup {
    /// Where one tick starts, ends, and where its label sits if it has one.
    private struct Tick {
        var from: CGPoint
        var to: CGPoint
        var label: CGPoint
    }

    /// Ticks every this many pixels, with a longer one every fifth.
    private static let tickSpacing = 10
    private static let majorEvery = 5
    private static let minorLength: CGFloat = 4
    private static let majorLength: CGFloat = 9
    /// Labels cost a text layer each, so they are capped; beyond this the ticks alone
    /// carry the scale and the badge carries the total.
    private static let maximumLabels = 24

    let container = CALayer()
    private let ticksLayer = CAShapeLayer()
    private var labelLayers: [CATextLayer] = []
    private let scale: DisplayScale
    private let labelFont: NSFont

    init(scale: DisplayScale) {
        self.scale = scale
        labelFont = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)

        container.isHidden = true
        ticksLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ticksLayer.fillColor = nil
        ticksLayer.lineWidth = 1
        // Hairlines on a dimmed screenshot read as grey; a shadow keeps them legible over
        // a white window as well as a dark one.
        ticksLayer.shadowColor = NSColor.black.cgColor
        ticksLayer.shadowOpacity = 0.6
        ticksLayer.shadowRadius = 1
        ticksLayer.shadowOffset = .zero
        container.addSublayer(ticksLayer)
    }

    func hide() {
        container.isHidden = true
    }

    /// Draws the ruler inside the top and left edges of `rect`.
    ///
    /// Inside rather than outside: the ruler belongs to the selection, and a ruler drawn
    /// outside would sit on the dimmed area where the user cannot see what it is
    /// measuring against.
    func show(along rect: CGRect) {
        let factor = scale.factor
        guard rect.width * factor >= CGFloat(Self.tickSpacing * 2),
              rect.height * factor >= CGFloat(Self.tickSpacing * 2)
        else {
            hide()
            return
        }

        container.isHidden = false
        let path = CGMutablePath()
        var labels: [(text: String, position: CGPoint)] = []

        // Horizontal ruler along the top edge.
        appendTicks(
            to: path,
            labels: &labels,
            extent: rect.width * factor,
            position: { offset, length in
                let x = rect.minX + offset / factor
                return Tick(
                    from: CGPoint(x: x, y: rect.minY),
                    to: CGPoint(x: x, y: rect.minY + length),
                    label: CGPoint(x: x + 3, y: rect.minY + Self.majorLength)
                )
            }
        )
        // Vertical ruler down the left edge.
        appendTicks(
            to: path,
            labels: &labels,
            extent: rect.height * factor,
            position: { offset, length in
                let y = rect.minY + offset / factor
                return Tick(
                    from: CGPoint(x: rect.minX, y: y),
                    to: CGPoint(x: rect.minX + length, y: y),
                    label: CGPoint(x: rect.minX + Self.majorLength + 2, y: y - 6)
                )
            }
        )

        ticksLayer.path = path
        layout(labels)
    }

    /// Walks one axis, adding ticks and collecting the labels the major ones want.
    private func appendTicks(
        to path: CGMutablePath,
        labels: inout [(text: String, position: CGPoint)],
        extent: CGFloat,
        position: (_ offsetInPixels: CGFloat, _ length: CGFloat) -> Tick
    ) {
        var index = 0
        var offset = 0
        while CGFloat(offset) <= extent {
            let isMajor = index % Self.majorEvery == 0
            let length = isMajor ? Self.majorLength : Self.minorLength
            let tick = position(CGFloat(offset), length)
            path.move(to: tick.from)
            path.addLine(to: tick.to)
            if isMajor, offset > 0, labels.count < Self.maximumLabels {
                labels.append(("\(offset)", tick.label))
            }
            offset += Self.tickSpacing
            index += 1
        }
    }

    /// Reuses the text layers rather than rebuilding them, because this runs on every
    /// mouse-move while a selection is being dragged.
    private func layout(_ labels: [(text: String, position: CGPoint)]) {
        while labelLayers.count < labels.count {
            let layer = CATextLayer()
            layer.font = labelFont
            layer.fontSize = labelFont.pointSize
            layer.foregroundColor = NSColor.white.cgColor
            layer.contentsScale = scale.factor
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.8
            layer.shadowRadius = 1
            layer.shadowOffset = .zero
            container.addSublayer(layer)
            labelLayers.append(layer)
        }

        for (index, layer) in labelLayers.enumerated() {
            guard index < labels.count else {
                layer.isHidden = true
                continue
            }
            layer.isHidden = false
            layer.string = labels[index].text
            layer.frame = CGRect(origin: labels[index].position, size: CGSize(width: 34, height: 12))
        }
    }
}
