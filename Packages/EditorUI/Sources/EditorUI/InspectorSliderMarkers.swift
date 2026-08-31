import SwiftUI

/// Tick marks revealed on hover, focus, or drag. The current value is a heavier
/// mark; signed ranges grow the grid outward from zero so the detent is one of
/// the ticks rather than a stray line between them.
struct InspectorSliderMarkers: View {
    let progress: CGFloat
    let zeroProgress: CGFloat?

    var body: some View {
        Canvas { context, size in
            let layout = MarkerLayout(size: size)
            if let zeroProgress {
                drawZeroAnchoredMarkers(in: &context, layout: layout, zeroProgress: zeroProgress)
            } else {
                drawEvenMarkers(in: &context, layout: layout)
            }
            drawMarker(
                in: &context,
                x: min(max(progress * size.width, 4), size.width - 4),
                layout: layout,
                style: MarkerStyle(height: 18, color: Color.primary.opacity(0.68), lineWidth: 3)
            )
        }
        .allowsHitTesting(false)
    }

    private func drawZeroAnchoredMarkers(
        in context: inout GraphicsContext,
        layout: MarkerLayout,
        zeroProgress: CGFloat
    ) {
        let zeroX = min(max(zeroProgress * layout.size.width, 4), layout.size.width - 4)
        let tick = MarkerStyle(height: 10, color: Color.primary.opacity(0.22), lineWidth: 1)
        for direction: CGFloat in [-1, 1] {
            for step in 1 ... 32 {
                let x = zeroX + direction * CGFloat(step) * layout.spacing
                if direction > 0, x > layout.trailingX {
                    break
                }
                if direction < 0, x < layout.leadingX {
                    break
                }
                guard x >= layout.leadingX, x <= layout.trailingX else { continue }
                drawMarker(in: &context, x: x, layout: layout, style: tick)
            }
        }
        drawMarker(
            in: &context,
            x: zeroX,
            layout: layout,
            style: MarkerStyle(height: 14, color: Color.primary.opacity(0.38), lineWidth: 1.5)
        )
    }

    private func drawEvenMarkers(in context: inout GraphicsContext, layout: MarkerLayout) {
        let tick = MarkerStyle(height: 10, color: Color.primary.opacity(0.22), lineWidth: 1)
        let markerCount = 7
        for index in 0 ..< markerCount {
            let fraction = CGFloat(index) / CGFloat(markerCount - 1)
            let x = layout.leadingX + fraction * (layout.trailingX - layout.leadingX)
            drawMarker(in: &context, x: x, layout: layout, style: tick)
        }
    }

    private func drawMarker(
        in context: inout GraphicsContext,
        x: CGFloat,
        layout: MarkerLayout,
        style: MarkerStyle
    ) {
        var path = Path()
        path.move(to: CGPoint(x: x, y: layout.centerY - style.height / 2))
        path.addLine(to: CGPoint(x: x, y: layout.centerY + style.height / 2))
        context.stroke(
            path,
            with: .color(style.color),
            style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round)
        )
    }
}

private struct MarkerLayout {
    let size: CGSize

    var centerY: CGFloat {
        size.height / 2
    }

    var leadingX: CGFloat {
        min(max(size.width * 0.34, 68), size.width - 40)
    }

    var trailingX: CGFloat {
        max(leadingX, size.width - 12)
    }

    var spacing: CGFloat {
        max((trailingX - leadingX) / 6, 8)
    }
}

private struct MarkerStyle {
    let height: CGFloat
    let color: Color
    let lineWidth: CGFloat
}
