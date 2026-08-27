import AnnotationModel
import CoreGraphics
import CoreText
import Foundation
import Shared

/// Replays a document into a bitmap for export (docs/04 §6).
///
/// Deliberately *not* a snapshot of the editing view. Rendering the commands again at the
/// image's native pixel scale is what makes an export sharp on any display, independent of
/// whatever zoom the editor happened to be at, and independent of the view hierarchy
/// existing at all — which is why this is testable without a window.
public struct AnnotationExportRenderer: Sendable {
    private let rasterizer = RedactionRasterizer()
    private let logger = KadrLog.logger(.capture)

    public init() {}

    public enum RenderError: Error, Equatable {
        case couldNotCreateContext
        case couldNotCreateImage
    }

    /// Flattens a document into a single image.
    ///
    /// - Parameters:
    ///   - baseImage: the capture, at pixel resolution.
    ///   - document: the annotations.
    ///   - includeAnnotations: false produces "Copy without annotations" (docs/03 §3),
    ///     which still honours the crop but draws nothing on top.
    ///   - randomSeed: pins pixelate jitter for tests.
    public func render(
        baseImage: CGImage,
        document: AnnotationDocument,
        includeAnnotations: Bool = true,
        randomSeed: UInt64? = nil
    ) throws -> CGImage {
        let scale = document.baseImage.scale
        let canvas = document.canvasRect

        // Redactions are burned into the image before anything is drawn over it, so the
        // exported file carries no removable overlay (docs/03 §3).
        let redactions = includeAnnotations ? document.commands.compactMap(\.redaction) : []
        let source = rasterizer.apply(redactions, to: baseImage, scale: scale, randomSeed: randomSeed)

        let pixelWidth = Int((canvas.width * scale).rounded())
        let pixelHeight = Int((canvas.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { throw RenderError.couldNotCreateContext }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: source.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.couldNotCreateContext
        }

        // Work in points with a top-left origin, matching the model, so no command has to
        // think about CoreGraphics' flipped space.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)

        if document.beautify != nil {
            BeautifyCompositor.compose(
                source: source,
                document: document,
                includeAnnotations: includeAnnotations,
                in: context
            ) { command, context in
                draw(command, in: context)
            }
        } else {
            context.translateBy(x: -canvas.minX, y: -canvas.minY)
            if document.crop?.canExpandCanvas == true {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(canvas)
            }
            context.draw(source, in: document.baseImage.bounds)
            if includeAnnotations {
                for command in document.commands {
                    draw(command, in: context)
                }
            }
        }

        guard let image = context.makeImage() else { throw RenderError.couldNotCreateImage }
        return image
    }

    // MARK: - Commands

    private func draw(_ command: AnnotationCommand, in context: CGContext) {
        switch command {
        case let .arrow(spec): drawArrow(spec, in: context)
        case let .shape(spec): drawShape(spec, in: context)
        case let .line(spec): drawLine(spec, in: context)
        case let .freehand(spec): drawStroke(spec.points, stroke: spec.stroke, in: context)
        case let .highlighter(spec): drawHighlighter(spec, in: context)
        case let .text(spec): drawText(spec, in: context)
        case let .counter(spec): drawCounter(spec, in: context)
        // Already burned into the image; drawing it again would be the removable overlay
        // this design exists to avoid.
        case .redaction: break
        // The crop is the canvas, applied by the transform above.
        case .crop: break
        case .beautify: break
        }
    }

    private func apply(_ stroke: StrokeStyle, to context: CGContext) {
        context.setStrokeColor(stroke.color.cgColor)
        context.setLineWidth(stroke.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if stroke.dashPattern.isEmpty {
            context.setLineDash(phase: 0, lengths: [])
        } else {
            context.setLineDash(phase: 0, lengths: stroke.dashPattern)
        }
    }

    private func drawArrow(_ spec: ArrowSpec, in context: CGContext) {
        apply(spec.stroke, to: context)
        context.beginPath()
        context.move(to: spec.start)
        if let control = spec.controlPoint {
            context.addQuadCurve(to: spec.end, control: control)
        } else {
            context.addLine(to: spec.end)
        }
        context.strokePath()
        drawArrowHead(spec, in: context)
    }

    /// The head sits at the end, pointing along the last bit of the shaft — which for a
    /// curved arrow is the tangent, not the line back to the start.
    private func drawArrowHead(_ spec: ArrowSpec, in context: CGContext) {
        let approach = spec.controlPoint ?? spec.start
        let angle = atan2(spec.end.y - approach.y, spec.end.x - approach.x)
        let length = max(spec.stroke.width * 3.5, 12)
        let spread = CGFloat.pi / 7

        let left = CGPoint(
            x: spec.end.x - length * cos(angle - spread),
            y: spec.end.y - length * sin(angle - spread)
        )
        let right = CGPoint(
            x: spec.end.x - length * cos(angle + spread),
            y: spec.end.y - length * sin(angle + spread)
        )

        switch spec.head {
        case .filled:
            context.setFillColor(spec.stroke.color.cgColor)
            context.beginPath()
            context.move(to: spec.end)
            context.addLine(to: left)
            context.addLine(to: right)
            context.closePath()
            context.fillPath()
        case .open:
            context.beginPath()
            context.move(to: left)
            context.addLine(to: spec.end)
            context.addLine(to: right)
            context.strokePath()
        case .concave:
            let notch = CGPoint(
                x: spec.end.x - length * 0.65 * cos(angle),
                y: spec.end.y - length * 0.65 * sin(angle)
            )
            context.setFillColor(spec.stroke.color.cgColor)
            context.beginPath()
            context.move(to: spec.end)
            context.addLine(to: left)
            context.addLine(to: notch)
            context.addLine(to: right)
            context.closePath()
            context.fillPath()
        }
    }

    private func drawShape(_ spec: ShapeSpec, in context: CGContext) {
        let path = CGMutablePath()
        let rect = spec.rect.standardized
        switch spec.kind {
        case .rectangle:
            path.addRect(rect)
        case let .roundedRectangle(cornerRadius):
            let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        case .ellipse:
            path.addEllipse(in: rect)
        }

        if let fill = spec.fill.color {
            context.setFillColor(fill.cgColor)
            context.addPath(path)
            context.fillPath()
        }
        if spec.stroke.width > 0 {
            apply(spec.stroke, to: context)
            context.addPath(path)
            context.strokePath()
        }
    }

    private func drawLine(_ spec: LineSpec, in context: CGContext) {
        apply(spec.stroke, to: context)
        context.beginPath()
        context.move(to: spec.start)
        context.addLine(to: spec.end)
        context.strokePath()
    }

    private func drawStroke(_ points: [CGPoint], stroke: StrokeStyle, in context: CGContext) {
        guard points.count > 1 else { return }
        apply(stroke, to: context)
        context.beginPath()
        context.move(to: points[0])
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    /// Highlighter strokes multiply, so overlapping text stays readable underneath
    /// (docs/03 §3).
    private func drawHighlighter(_ spec: HighlighterSpec, in context: CGContext) {
        context.saveGState()
        context.setBlendMode(.multiply)
        drawStroke(spec.points, stroke: spec.stroke, in: context)
        context.restoreGState()
    }

    private func drawText(_ spec: TextSpec, in context: CGContext) {
        guard !spec.string.isEmpty else { return }

        if let background = spec.style.backgroundColor {
            context.setFillColor(background.cgColor)
            let pill = spec.rect.insetBy(dx: -6, dy: -4)
            context.addPath(CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
        }

        let font = CTFontCreateWithName(
            spec.style.fontName as CFString,
            spec.style.fontSize,
            nil
        )
        // CoreText attribute names rather than AppKit's, so the export path stays free
        // of a UI framework and could run in the XPC helper.
        let attributed = NSAttributedString(string: spec.string, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): spec.style.color.cgColor
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: spec.rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        // Text draws in CoreGraphics' own orientation, so the flip applied to the whole
        // canvas has to be undone around it.
        context.saveGState()
        context.translateBy(x: 0, y: spec.rect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func drawCounter(_ spec: CounterSpec, in context: CGContext) {
        let rect = CGRect(
            x: spec.center.x - spec.radius,
            y: spec.center.y - spec.radius,
            width: spec.radius * 2,
            height: spec.radius * 2
        )
        context.setFillColor(spec.fill.cgColor)
        context.fillEllipse(in: rect)

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, spec.radius * 1.1, nil)
        let attributed = NSAttributedString(string: "\(spec.number)", attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): spec.textColor.cgColor
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

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

extension AnnotationCommand {
    /// The redaction this command carries, if it is one.
    var redaction: RedactionSpec? {
        if case let .redaction(spec) = self {
            return spec
        }
        return nil
    }
}

public extension AnnotationColor {
    /// A CoreGraphics colour in sRGB, which is the space captures are tagged with.
    var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: [red, green, blue, alpha]
        ) ?? CGColor(gray: 0, alpha: alpha)
    }
}
