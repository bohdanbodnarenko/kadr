import AnnotationModel
import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// Drawing a measurement, for both the editing layer tree and the export (docs/06 M21).
///
/// Its own file because a measurement is two things at once — geometry and a number — and
/// the number has to be produced identically in the layer tree and in the exported file.
/// One place to get it wrong is better than two.
enum MeasureRendering {
    /// How far the end caps stick out either side of the line.
    static func capHalfLength(_ stroke: AnnotationModel.StrokeStyle) -> CGFloat {
        max(stroke.width * 3, 8)
    }

    /// The line (with its end caps) or the box outline.
    static func path(_ spec: MeasureSpec) -> CGPath {
        let path = CGMutablePath()
        guard !spec.measuresBox else {
            path.addRect(spec.rect.standardized)
            return path
        }

        path.move(to: spec.start)
        path.addLine(to: spec.end)

        // Perpendicular ticks at each end, so the measurement reads as a dimension line
        // rather than as an ordinary stroke someone drew.
        let angle = atan2(spec.end.y - spec.start.y, spec.end.x - spec.start.x)
        let half = capHalfLength(spec.stroke)
        let offsetX = -sin(angle) * half
        let offsetY = cos(angle) * half
        for point in [spec.start, spec.end] {
            path.move(to: CGPoint(x: point.x - offsetX, y: point.y - offsetY))
            path.addLine(to: CGPoint(x: point.x + offsetX, y: point.y + offsetY))
        }
        return path
    }

    /// Where the readout sits.
    ///
    /// Beside the line rather than on it, and above a box rather than inside it: the
    /// point of a measurement is to see the thing being measured.
    static func labelRect(_ spec: MeasureSpec, size: CGSize) -> CGRect {
        let padded = CGSize(width: size.width + 12, height: size.height + 8)
        guard !spec.measuresBox else {
            let box = spec.rect.standardized
            return CGRect(
                x: box.midX - padded.width / 2,
                y: box.minY - padded.height - 6,
                width: padded.width,
                height: padded.height
            )
        }

        let midpoint = CGPoint(x: (spec.start.x + spec.end.x) / 2, y: (spec.start.y + spec.end.y) / 2)
        let angle = atan2(spec.end.y - spec.start.y, spec.end.x - spec.start.x)
        let offset = capHalfLength(spec.stroke) + padded.height / 2
        return CGRect(
            x: midpoint.x - sin(angle) * offset - padded.width / 2,
            y: midpoint.y + cos(angle) * offset - padded.height / 2,
            width: padded.width,
            height: padded.height
        )
    }

    /// The readout, as CoreText attributes — no AppKit, so the export path can run
    /// anywhere (docs/04 §6).
    static func attributedLabel(_ spec: MeasureSpec, imageScale: CGFloat) -> NSAttributedString {
        let font = TextLayout.font(named: spec.labelStyle.fontName, size: spec.labelStyle.fontSize)
        return NSAttributedString(string: spec.readout(scale: imageScale), attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): spec.labelStyle.color.cgColor
        ])
    }

    static func labelSize(_ label: NSAttributedString) -> CGSize {
        let line = CTLineCreateWithAttributedString(label)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        return CGSize(width: bounds.width, height: bounds.height)
    }
}

extension AnnotationLayerFactory {
    /// The editing-time layer: the dimension geometry plus its readout.
    static func measureLayer(
        _ spec: MeasureSpec,
        contentsScale: CGFloat,
        imageScale: CGFloat
    ) -> CALayer {
        let container = CALayer()
        container.addSublayer(measureShapeLayer(spec))
        container.addSublayer(measureLabelLayer(spec, contentsScale: contentsScale, imageScale: imageScale))
        return container
    }

    /// Rebuilds a measurement's sublayers in place, for the drag path.
    static func updateMeasureLayer(_ layer: CALayer, spec: MeasureSpec, imageScale: CGFloat) {
        guard let sublayers = layer.sublayers, sublayers.count == 2 else { return }
        (sublayers[0] as? CAShapeLayer)?.path = MeasureRendering.path(spec)

        let label = MeasureRendering.attributedLabel(spec, imageScale: imageScale)
        let text = sublayers[1]
        (text as? CATextLayer)?.string = label
        text.frame = MeasureRendering.labelRect(spec, size: MeasureRendering.labelSize(label))
    }

    private static func measureShapeLayer(_ spec: MeasureSpec) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.path = MeasureRendering.path(spec)
        shape.strokeColor = spec.stroke.color.cgColor
        shape.lineWidth = spec.stroke.width
        shape.fillColor = nil
        shape.lineCap = .butt
        if spec.measuresBox {
            // Dashed, so a measurement box is never mistaken for a rectangle annotation.
            shape.lineDashPattern = [6, 4]
        }
        return shape
    }

    private static func measureLabelLayer(
        _ spec: MeasureSpec,
        contentsScale: CGFloat,
        imageScale: CGFloat
    ) -> CATextLayer {
        let label = MeasureRendering.attributedLabel(spec, imageScale: imageScale)
        let text = CATextLayer()
        text.string = label
        text.frame = MeasureRendering.labelRect(spec, size: MeasureRendering.labelSize(label))
        text.alignmentMode = .center
        text.contentsScale = contentsScale
        if let background = spec.labelStyle.backgroundColor {
            text.backgroundColor = background.cgColor
            text.cornerRadius = 4
        }
        return text
    }
}
