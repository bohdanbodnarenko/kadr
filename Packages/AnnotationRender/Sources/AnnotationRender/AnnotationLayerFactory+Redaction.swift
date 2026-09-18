import AnnotationModel
import CoreGraphics
import Foundation
import QuartzCore

/// The live redaction preview: what a redaction layer shows while it is edited
/// (docs/03 §3, docs/10 R1).
extension AnnotationLayerFactory {
    /// Samples the capture under the box so the editor shows a real blur, not a grey
    /// stand-in (Screendrop's live redaction). Export still burns the effect in.
    /// One rasterizer, not one per frame.
    ///
    /// This is built on every mouse-move while a redaction box is dragged, and building one
    /// creates an `os.Logger` each time.
    private static let redactionRasterizer = RedactionRasterizer()

    static func redactionPreviewLayer(_ spec: RedactionSpec, context: AnnotationLayerContext) -> CALayer {
        let layer = CALayer()
        applyRedactionPreview(to: layer, spec: spec, context: context)
        return layer
    }

    static func applyRedactionPreview(to layer: CALayer, spec: RedactionSpec, context: AnnotationLayerContext) {
        layer.frame = spec.rect.standardized
        guard spec.rotation != 0 else {
            alignedContainer(of: layer, creating: false)?.removeFromSuperlayer()
            presentRedaction(on: layer, spec: spec, context: context)
            return
        }
        // Rotated: the effect is what the export burns in — the capture's own pixels over
        // the box around the turned rect, clipped by it — so the preview shows that box in
        // a sublayer turned back the other way. The layer's rotation and the sublayer's
        // cancel, the pixels stay where they are in the image, and the rotated layer's
        // bounds do the clipping (docs/16 ED-10).
        layer.contents = nil
        layer.backgroundColor = nil
        layer.masksToBounds = true
        RedactionLayerPresenter.gestureSublayer(of: layer, creating: false)?.isHidden = true
        let area = AnnotationRotation.aabb(spec.rect, radians: spec.rotation)
        guard let container = alignedContainer(of: layer, creating: true) else { return }
        container.bounds = CGRect(origin: .zero, size: area.size)
        container.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        container.transform = CATransform3DMakeRotation(-spec.rotation, 0, 0, 1)
        var aligned = spec
        aligned.rect = area
        aligned.rotation = 0
        presentRedaction(on: container, spec: aligned, context: context)
    }

    private static let alignedContainerName = "kadr.redaction.aligned"

    private static func alignedContainer(of layer: CALayer, creating: Bool) -> CALayer? {
        if let existing = layer.sublayers?.first(where: { $0.name == alignedContainerName }) {
            return existing
        }
        guard creating else { return nil }
        let container = CALayer()
        container.name = alignedContainerName
        container.actions = [
            "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "transform": NSNull()
        ]
        layer.addSublayer(container)
        return container
    }

    private static func presentRedaction(on layer: CALayer, spec: RedactionSpec, context: AnnotationLayerContext) {
        layer.masksToBounds = true
        layer.contentsGravity = .resize
        // Linear, not nearest: a nearest-neighbour upsample of a Gaussian looks like a
        // mosaic, which is the pixelate tool's job (docs/03 §3).
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.borderWidth = 0

        guard let previews = context.redaction else {
            // No source: render inline, uncached. Tests, and nothing on the drag path.
            if let baseImage = context.baseImage,
               let preview = redactionRasterizer.preview(spec, from: baseImage, scale: context.imageScale) {
                showExact(preview, on: layer, spec: spec)
            } else {
                showPlaceholder(on: layer)
            }
            return
        }
        RedactionLayerPresenter(layer: layer, spec: spec, context: previews).present()
    }

    static func showExact(_ preview: CGImage, on layer: CALayer, spec: RedactionSpec) {
        RedactionLayerPresenter.gestureSublayer(of: layer, creating: false)?.isHidden = true
        layer.contents = preview
        let width = max(spec.rect.width, 1)
        layer.contentsScale = max(CGFloat(preview.width) / width, 1)
        layer.backgroundColor = nil
    }

    /// Tests and a failed sample still need a visible region.
    static func showPlaceholder(on layer: CALayer) {
        RedactionLayerPresenter.gestureSublayer(of: layer, creating: false)?.isHidden = true
        layer.contents = nil
        layer.backgroundColor = CGColor(gray: 0.45, alpha: 0.55)
    }
}

/// Everything a layer needs from the canvas beyond its own command.
public struct AnnotationLayerContext {
    /// The base image's pixels per point, which the measurement readout and the live
    /// redaction preview both need.
    public var imageScale: CGFloat
    /// The capture's pixels, so a blur samples what is actually under the box rather than
    /// drawing a grey stand-in.
    public var baseImage: CGImage?
    public var canvasRect: CGRect?
    /// Where redaction previews come from. Without one a redaction is rendered inline and
    /// uncached, which is what tests want.
    public var redaction: RedactionPreviewContext?

    public init(
        imageScale: CGFloat = 1,
        baseImage: CGImage? = nil,
        canvasRect: CGRect? = nil,
        redaction: RedactionPreviewContext? = nil
    ) {
        self.imageScale = imageScale
        self.baseImage = baseImage
        self.canvasRect = canvasRect
        self.redaction = redaction
    }
}

/// How a canvas wants its redaction previews (docs/10 R1).
public struct RedactionPreviewContext {
    public let source: RedactionPreviewSource
    /// True while the box is being drawn, dragged or resized: show the whole-capture
    /// stand-in rather than rendering the box.
    public let isLive: Bool

    public init(source: RedactionPreviewSource, isLive: Bool) {
        self.source = source
        self.isLive = isLive
    }
}

/// Decides what one redaction layer shows, given what is ready.
///
/// The order is: the exact preview if it is cached; while dragging, the stand-in; once
/// settled, the stand-in (or whatever is already there) until the exact render arrives off
/// the main actor. Only a layer with nothing on screen at all renders inline, so opening a
/// document does not flash grey boxes.
private struct RedactionLayerPresenter {
    let layer: CALayer
    let spec: RedactionSpec
    let context: RedactionPreviewContext

    private var source: RedactionPreviewSource {
        context.source
    }

    static let gestureSublayerName = "kadr.redaction.gesture"

    func present() {
        if let exact = source.cachedExact(spec) {
            AnnotationLayerFactory.showExact(exact, on: layer, spec: spec)
            return
        }
        if case .erase = spec.style {
            // Reading a one-pixel ring and filling a box is cheap enough per event; only
            // the cache is skipped mid-drag, where every entry would be a miss next time.
            if let preview = source.renderExactNow(spec, caching: !context.isLive) {
                AnnotationLayerFactory.showExact(preview, on: layer, spec: spec)
            } else {
                AnnotationLayerFactory.showPlaceholder(on: layer)
            }
            return
        }
        if context.isLive {
            presentLive()
        } else {
            presentSettled()
        }
    }

    private var isShowingSomething: Bool {
        layer.contents != nil || Self.gestureSublayer(of: layer, creating: false)?.isHidden == false
    }

    private func presentLive() {
        if let stand = source.gestureImage(for: spec.style), showGesture(stand) {
            return
        }
        // The stand-in is still rendering. A box already showing something keeps it for
        // the frame or two that takes; a brand-new one gets the real thing once, uncached.
        guard !isShowingSomething else { return }
        if let preview = source.renderExactNow(spec, caching: false) {
            AnnotationLayerFactory.showExact(preview, on: layer, spec: spec)
        } else {
            AnnotationLayerFactory.showPlaceholder(on: layer)
        }
    }

    private func presentSettled() {
        let hasStandIn = source.hasGestureImage(for: spec.style)
        if isShowingSomething || hasStandIn {
            // Keep (or put up) the approximation, and replace it when the exact one lands.
            // A stand-in is only *used* here, never started: a settled style change must
            // not cost a whole-capture render nobody is dragging.
            if hasStandIn, let stand = source.gestureImage(for: spec.style) {
                _ = showGesture(stand)
            }
            source.requestExact(spec)
            return
        }
        if let preview = source.renderExactNow(spec) {
            AnnotationLayerFactory.showExact(preview, on: layer, spec: spec)
        } else {
            AnnotationLayerFactory.showPlaceholder(on: layer)
        }
    }

    /// Shows the part of the stand-in under the box, in a sublayer the box clips.
    private func showGesture(_ stand: RedactionGestureImage) -> Bool {
        let scale = source.scale
        let box = RedactionRasterizer.pixelBox(of: spec.rect, scale: scale)
        guard scale > 0, let region = stand.region(covering: box),
              let sublayer = Self.gestureSublayer(of: layer, creating: true)
        else { return false }
        let origin = spec.rect.standardized.origin
        sublayer.frame = CGRect(
            x: region.pixelRect.minX / scale - origin.x,
            y: region.pixelRect.minY / scale - origin.y,
            width: region.pixelRect.width / scale,
            height: region.pixelRect.height / scale
        )
        sublayer.contents = region.image
        sublayer.contentsGravity = .resize
        // A mosaic's stand-in is one pixel per cell; nearest keeps the cells square.
        if case .pixelate = spec.style {
            sublayer.magnificationFilter = .nearest
        } else {
            sublayer.magnificationFilter = .linear
        }
        sublayer.minificationFilter = .linear
        sublayer.isHidden = false
        layer.contents = nil
        layer.backgroundColor = nil
        return true
    }

    static func gestureSublayer(of layer: CALayer, creating: Bool) -> CALayer? {
        if let existing = layer.sublayers?.first(where: { $0.name == gestureSublayerName }) {
            return existing
        }
        guard creating else { return nil }
        let sublayer = CALayer()
        sublayer.name = gestureSublayerName
        sublayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer.addSublayer(sublayer)
        return sublayer
    }
}
