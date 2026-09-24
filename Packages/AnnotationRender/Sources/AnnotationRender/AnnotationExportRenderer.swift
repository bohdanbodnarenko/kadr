import AnnotationModel
import CoreGraphics
import CoreText
import Foundation
import os
import Shared

/// Replays a document into a bitmap for export (docs/04 §6).
///
/// Deliberately *not* a snapshot of the editing view. Rendering the commands again at the
/// image's native pixel scale is what makes an export sharp on any display, independent of
/// whatever zoom the editor happened to be at, and independent of the view hierarchy
/// existing at all — which is why this is testable without a window.
public struct AnnotationExportRenderer: Sendable {
    private let rasterizer = RedactionRasterizer()
    private let subjectLift = SubjectLiftCompositor()
    private let logger = KadrLog.logger(.capture)
    let objectShadowsEnabled: Bool

    public init(objectShadowsEnabled: Bool? = nil) {
        self.objectShadowsEnabled = objectShadowsEnabled ?? ObjectShadowPolicy.isEnabled()
    }

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
    ///     which still honours the crop and burns in redactions (T-ED-12) but draws
    ///     nothing else on top.
    ///   - applyOrientation: false skips rotate/flip, for the in-editor flatten that
    ///     already sits inside the canvas's oriented layer host.
    ///   - exportScale: 1 is native pixels; smaller values downscale Copy/Save
    ///     (docs/03 §3 P2). Ignored when `applyOrientation` is false — the canvas
    ///     flatten must match the view, not the export size.
    public func render(
        baseImage: CGImage,
        document: AnnotationDocument,
        includeAnnotations: Bool = true,
        randomSeed: UInt64? = nil,
        applyOrientation: Bool = true,
        exportScale: CGFloat = 1
    ) throws -> CGImage {
        try render(
            baseImage: baseImage,
            document: document,
            options: RenderOptions(
                includeAnnotations: includeAnnotations,
                randomSeed: randomSeed,
                applyOrientation: applyOrientation,
                exportScale: exportScale
            )
        )
    }

    /// How one render is asked for.
    struct RenderOptions {
        var includeAnnotations = true
        var randomSeed: UInt64?
        var applyOrientation = true
        var exportScale: CGFloat = 1
        /// The pixels-per-point measurement readouts report, when the render itself is at a
        /// different density (a preview). Nil means the document's own.
        var labelScale: CGFloat?
    }

    func render(baseImage: CGImage, document: AnnotationDocument, options: RenderOptions) throws -> CGImage {
        let includeAnnotations = options.includeAnnotations
        let randomSeed = options.randomSeed
        let applyOrientation = options.applyOrientation
        let exportScale = options.exportScale
        let scale = document.baseImage.scale
        let readoutScale = options.labelScale ?? scale
        let canvas = document.canvasRect

        // Redactions are burned into the image before anything is drawn over it, so the
        // exported file carries no removable overlay (docs/03 §3). They stay even in "copy
        // without annotations": a redaction is a promise about what leaves the Mac, not a
        // drawing on top, and dropping it leaked the blurred secret in one click (T-ED-12).
        let redactions = document.commands.compactMap(\.redaction)
        let redacted = rasterizer.apply(redactions, to: baseImage, scale: scale, randomSeed: randomSeed)

        // Background removal is part of what the base image *is*, like a crop — so it
        // applies even to "copy without annotations", which is about the drawing on top
        // rather than about the canvas (docs/06 M23).
        let source = document.subjectLift.map { subjectLift.apply($0, to: redacted) } ?? redacted

        let pixelWidth = Int((canvas.width * scale).rounded())
        let pixelHeight = Int((canvas.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { throw RenderError.couldNotCreateContext }

        guard let context = Self.makeContext(
            width: pixelWidth,
            height: pixelHeight,
            matching: source
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
                draw(command, in: context, imageScale: readoutScale)
            }
        } else {
            context.translateBy(x: -canvas.minX, y: -canvas.minY)
            drawPlainCanvas(
                CardContents(
                    source: source,
                    document: document,
                    includeAnnotations: includeAnnotations,
                    drawCommand: { command, target in draw(command, in: target, imageScale: readoutScale) }
                ),
                canvas: canvas,
                scale: scale,
                readoutScale: readoutScale,
                in: context
            )
        }

        guard let image = context.makeImage() else { throw RenderError.couldNotCreateImage }
        let finished = finish(
            image,
            document: document,
            canvas: canvas,
            scale: scale,
            applyOrientation: applyOrientation,
            includeWatermark: includeAnnotations
        )
        return Self.downscaled(finished, by: applyOrientation ? exportScale : 1) ?? finished
    }

    /// A canvas that can hold everything the source image can (docs/06 M25).
    ///
    /// An HDR capture is 16 bits per channel, often half-float; rendering it into the
    /// 8-bit context every other export uses would quantise and clip it, which is exactly
    /// what capturing in HDR was meant to avoid. Falls back to 8 bits when the deeper
    /// context cannot be made, because a slightly flattened export beats none.
    /// Internal, not private: the canvas assembly lives in
    /// `AnnotationExportRenderer+Canvas.swift`, and `private` is file-scoped.
    static func makeContext(width: Int, height: Int, matching source: CGImage) -> CGContext? {
        let space = source.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        if source.bitsPerComponent > 8 {
            var info = CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
            if source.bitmapInfo.contains(.floatComponents) {
                info |= CGBitmapInfo.floatComponents.rawValue
            }
            if let deep = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: info
            ) {
                return deep
            }
        }

        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    // MARK: - Commands

    /// Internal, not private: the canvas assembly draws commands too.
    func draw(_ command: AnnotationCommand, in context: CGContext, imageScale: CGFloat) {
        // Turned about the same pivot as the canvas layer and the hit test (docs/16 ED-10).
        // The export used to ignore rotation entirely, so a rotated shape was saved level.
        let radians = command.rotation
        guard radians == 0 else {
            context.saveGState()
            context.concatenate(AnnotationRotation.transform(
                radians: radians,
                around: AnnotationHitTesting.rotationPivot(of: command)
            ))
            drawUnrotated(command, in: context, imageScale: imageScale)
            context.restoreGState()
            return
        }
        drawUnrotated(command, in: context, imageScale: imageScale)
    }

    private func drawUnrotated(_ command: AnnotationCommand, in context: CGContext, imageScale: CGFloat) {
        switch command {
        case let .arrow(spec): drawArrow(spec, in: context)
        case let .shape(spec): drawShape(spec, in: context)
        case let .line(spec): drawLine(spec, in: context)
        case let .freehand(spec):
            drawStroke(
                spec.isSmoothed ? StrokeSmoothing.smoothed(spec.points) : spec.points,
                stroke: spec.stroke,
                in: context
            )
        case let .highlighter(spec): drawHighlighter(spec, in: context)
        default: drawContent(command, in: context, imageScale: imageScale)
        }
    }

    /// The commands that draw text or an effect — and the three that deliberately draw
    /// nothing here.
    func drawContent(_ command: AnnotationCommand, in context: CGContext, imageScale: CGFloat) {
        switch command {
        case let .text(spec): drawText(spec, in: context)
        case let .counter(spec): drawCounter(spec, in: context)
        case let .measure(spec): drawMeasure(spec, in: context, imageScale: imageScale)
        case let .image(spec): drawImage(spec, in: context)
        case .spotlight:
            // Drawn once as a composite after redactions (docs/16 ED-9).
            break
        // A redaction is already burned into the image; drawing it again would be the
        // removable overlay this design exists to avoid. The crop and the beautify
        // backdrop are the canvas itself, applied by the transform above.
        default: break
        }
    }

    /// Dims the canvas except for every spotlight hole, so two holes stay equally bright.
    func drawSpotlights(of document: AnnotationDocument, in context: CGContext) {
        guard let composite = SpotlightComposite.from(commands: document.resolvedCommands) else { return }
        let canvas = context.boundingBoxOfClipPath
        guard !canvas.isNull, !canvas.isInfinite, canvas.width > 0, canvas.height > 0 else { return }
        context.saveGState()
        context.setFillColor(gray: 0, alpha: composite.dimOpacity)
        context.addPath(composite.path(in: canvas))
        context.drawPath(using: .eoFill)
        context.restoreGState()
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
        let geometry = ArrowGeometry.make(spec)
        apply(spec.stroke, to: context)
        context.addPath(geometry.shaft)
        context.strokePath()
        drawHead(geometry.startHead, stroke: spec.stroke, in: context)
        drawHead(geometry.endHead, stroke: spec.stroke, in: context)
    }

    private func drawHead(_ head: ArrowGeometry.Head?, stroke: StrokeStyle, in context: CGContext) {
        guard let head else { return }
        apply(stroke, to: context)
        context.addPath(head.path)
        if head.isFilled {
            context.setFillColor(stroke.color.cgColor)
            context.drawPath(using: .fillStroke)
        } else {
            context.strokePath()
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
        TextRendering.draw(spec, in: context)
    }

    /// The dimension geometry and its readout (docs/06 M21).
    ///
    /// Replayed rather than snapshotted, like every other command, so an exported
    /// measurement is crisp at the capture's own pixel scale.
    private func drawMeasure(_ spec: MeasureSpec, in context: CGContext, imageScale: CGFloat) {
        apply(spec.stroke, to: context)
        if spec.measuresBox {
            context.setLineDash(phase: 0, lengths: [6, 4])
        }
        context.setLineCap(.butt)
        context.addPath(MeasureRendering.path(spec))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        let label = MeasureRendering.attributedLabel(spec, imageScale: imageScale)
        let size = MeasureRendering.labelSize(label)
        let rect = MeasureRendering.labelRect(spec, size: size)

        if let background = spec.labelStyle.backgroundColor {
            context.setFillColor(background.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
        }

        // Text draws in CoreGraphics' own orientation, so the canvas flip is undone here.
        let line = CTLineCreateWithAttributedString(label)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.saveGState()
        context.translateBy(x: 0, y: rect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(
            x: rect.midX - bounds.width / 2 - bounds.minX,
            y: rect.midY - bounds.height / 2 - bounds.minY
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
