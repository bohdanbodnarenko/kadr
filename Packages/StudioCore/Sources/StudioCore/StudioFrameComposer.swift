import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// One output frame, built from one source frame (docs/09 U3.2, U3.3).
///
/// The single place a studio frame is assembled. The preview and the export both call this
/// — not "both implement the same thing", which is how a preview ends up half a pixel
/// different from the file and nobody finds out until the render finishes.
///
/// CoreImage rather than CoreGraphics because the work is a crop, a scale, a few composites
/// and an average of several samples, all of which are one GPU pass here and a readback per
/// step there. The overlays are drawn once into `CGImage`s and cached, because rasterising a
/// caption sixty times a second is the kind of thing that turns a 2× export into a 6× one.
///
/// CoreImage's origin is bottom-left and everything Kadr records is top-left, so every
/// conversion goes through `flipped(_:in:)` rather than an ad-hoc subtraction — the same
/// discipline `Shared.Geometry` enforces across the AppKit/CG boundary.
public struct StudioFrameComposer: Sendable {
    public let plan: StudioRenderPlan
    public let edit: StudioEdit
    public let telemetry: InputTelemetry

    private let reconstruction: CursorReconstruction
    private let cursorPath: [CGPoint]
    private let cursorImages: [CGImage?]
    private let frameDuration: TimeInterval

    /// The most the camera may enlarge an overlay.
    ///
    /// Overlays scale with the camera, because a cursor and a ripple are part of the scene
    /// — a pointer that stayed the same size through a zoom would slide across the picture
    /// like a sticker on the lens. But only so far: at 4× an unclamped system cursor
    /// becomes a dinner plate, which is its own kind of wrong.
    static let maximumOverlayScale: CGFloat = 2.5

    public init(
        plan: StudioRenderPlan,
        edit: StudioEdit,
        telemetry: InputTelemetry,
        frameRate: Int = 60,
        spring: MotionSpring = MotionSpring()
    ) {
        self.plan = plan
        self.edit = edit
        // Rebased once, here (docs/10 R0.2). The sidecar is written in source time and
        // every method below is called with an edited-time playhead; converting at the
        // boundary is what stops the two being confused anywhere past it, and is why the
        // preview and the export agree by construction rather than by both remembering.
        self.telemetry = telemetry.rebased(to: edit.clips)
        frameDuration = 1.0 / Double(max(frameRate, 1))
        reconstruction = CursorReconstruction(spring: spring)
        cursorPath = reconstruction.path(for: self.telemetry, duration: plan.duration)
        // Decoded once. A cursor PNG is a few hundred bytes and there are rarely more than
        // a dozen of them, but decoding one per frame is a decode per frame.
        cursorImages = self.telemetry.cursors.map { CursorArtwork.decode($0.pngData) }
    }

    /// The output frame at `time`.
    ///
    /// - Parameters:
    ///   - source: the screen frame, with its extent in recorded pixels.
    ///   - camera: the webcam frame, if there is one for this instant.
    public func frame(at time: TimeInterval, source: CIImage, camera: CIImage?) -> CIImage {
        var image = viewport(at: time, source: source)
        image = overlays(at: time, over: image)
        if let camera, edit.camera.isVisible {
            image = bubble(camera, over: image)
        }
        // Cropped last and always: a composite whose extent has grown past the frame — a
        // ripple at the edge, a bubble flush to the corner — writes a pixel buffer with a
        // silently shifted origin, and the whole video comes out offset.
        return image.cropped(to: CGRect(origin: .zero, size: plan.outputSize))
    }

    // MARK: - The camera

    /// The source frame cropped and scaled to the viewport, with motion blur if it is moving.
    private func viewport(at time: TimeInterval, source: CIImage) -> CIImage {
        let blur = MotionBlurPlan.plan(isMoving: plan.isMoving(at: time))
        guard blur.isBlurring else {
            return sample(at: time, source: source)
        }

        // Motion blur from the *camera*, not from the content: the source frame is the same
        // for every sample and only the viewport moves. That is what a real shutter does
        // during a pan, it costs one extra crop per sample rather than one extra decode,
        // and it is the difference between a zoom that glides and one that strobes.
        let offsets = blur.offsets(frameDuration: frameDuration)
        var accumulated: CIImage?
        let weight = 1.0 / Double(offsets.count)
        for offset in offsets {
            let sampled = sample(at: max(0, time + offset), source: source)
            let faded = sampled.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)
            ])
            accumulated = accumulated.map {
                faded.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: $0])
            } ?? faded
        }
        // Opaque again: the samples were averaged through the alpha channel, and a frame
        // that stays translucent composites its own overlays into a ghost.
        return (accumulated ?? sample(at: time, source: source))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
    }

    /// One crop-and-scale of the source frame, at one instant.
    private func sample(at time: TimeInterval, source: CIImage) -> CIImage {
        let rect = plan.sourceRect(at: time)
        guard rect.width > 0, rect.height > 0 else { return source }

        // Source frames arrive with a bottom-left extent; the plan speaks top-left.
        let flipped = CGRect(
            x: rect.minX,
            y: plan.sourceSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let cropped = source.cropped(to: flipped.offsetBy(dx: source.extent.minX, dy: source.extent.minY))
        let scale = plan.outputSize.width / rect.width
        return cropped
            .transformed(by: CGAffineTransform(translationX: -cropped.extent.minX, y: -cropped.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Overlays

    /// A click whose ripple is still running.
    ///
    /// A named type rather than three optional bindings in one `if`, because a ripple needs
    /// both its progress and the exact position of the press — the smoothed cursor is not
    /// where the click landed — and the two are only ever meaningful together.
    private struct Press {
        let progress: Double
        let origin: CGPoint

        init?(_ cursor: ReconstructedCursor) {
            guard let progress = cursor.clickProgress, let origin = cursor.clickPosition else { return nil }
            self.progress = progress
            self.origin = origin
        }
    }

    /// The cursor, its ripple and any keystroke caption, in output space.
    private func overlays(at time: TimeInterval, over base: CIImage) -> CIImage {
        var image = base
        let cursor = reconstruction.cursor(at: time, path: cursorPath, telemetry: telemetry)
        let scale = min(plan.scale(at: time), Self.maximumOverlayScale)

        if edit.showsClicks, let press = cursor.flatMap(Press.init) {
            image = compositing(
                ripple(progress: press.progress, scale: scale),
                at: press.origin,
                time: time,
                over: image
            )
        }
        if edit.showsCursor, let cursor {
            image = compositingCursor(cursor, scale: scale, time: time, over: image)
        }
        if edit.showsKeystrokes, let caption = caption(at: time) {
            image = compositing(caption.image, at: nil, time: time, over: image, placement: caption.placement)
        }
        return image
    }

    /// Draws the recorded cursor artwork at the reconstructed position.
    private func compositingCursor(
        _ cursor: ReconstructedCursor,
        scale: CGFloat,
        time: TimeInterval,
        over base: CIImage
    ) -> CIImage {
        guard let index = cursor.cursorIndex,
              telemetry.cursors.indices.contains(index),
              let artwork = cursorImages[index]
        else {
            return base
        }
        let recorded = telemetry.cursors[index]
        let size = CGSize(width: recorded.size.width * scale, height: recorded.size.height * scale)
        guard size.width > 0, size.height > 0 else { return base }

        // The hotspot is in the image's own pixels; the drawn image is in points scaled by
        // the camera. Converting through the recorded point size is what keeps an I-beam's
        // tip on the text rather than up and to the left of it.
        let pixelsPerPoint = recorded.size.width > 0
            ? CGFloat(artwork.width) / recorded.size.width
            : 1
        let hotspot = CGPoint(
            x: recorded.hotspot.x / max(pixelsPerPoint, 0.0001) * scale,
            y: recorded.hotspot.y / max(pixelsPerPoint, 0.0001) * scale
        )
        let topLeft = plan.outputPoint(cursor.position, at: time)
        let rect = CGRect(
            x: topLeft.x - hotspot.x,
            y: topLeft.y - hotspot.y,
            width: size.width,
            height: size.height
        )
        return composite(CIImage(cgImage: artwork), into: rect, over: base)
    }

    /// Composites an already-sized overlay image around a source-space point.
    private func compositing(
        _ overlay: CGImage?,
        at sourcePoint: CGPoint?,
        time: TimeInterval,
        over base: CIImage,
        placement: CGRect? = nil
    ) -> CIImage {
        guard let overlay else { return base }
        let rect: CGRect
        if let placement {
            rect = placement
        } else if let sourcePoint {
            let centre = plan.outputPoint(sourcePoint, at: time)
            rect = CGRect(
                x: centre.x - CGFloat(overlay.width) / 2,
                y: centre.y - CGFloat(overlay.height) / 2,
                width: CGFloat(overlay.width),
                height: CGFloat(overlay.height)
            )
        } else {
            return base
        }
        return composite(CIImage(cgImage: overlay), into: rect, over: base)
    }

    /// Places an image into a top-left rect of the output and composites it.
    private func composite(_ overlay: CIImage, into rect: CGRect, over base: CIImage) -> CIImage {
        guard overlay.extent.width > 0, overlay.extent.height > 0 else { return base }
        let scaleX = rect.width / overlay.extent.width
        let scaleY = rect.height / overlay.extent.height
        let placed = overlay
            .transformed(by: CGAffineTransform(translationX: -overlay.extent.minX, y: -overlay.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(
                translationX: rect.minX,
                // Top-left rect into CoreImage's bottom-left space.
                y: plan.outputSize.height - rect.maxY
            ))
        return placed.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: base
        ])
    }

    // MARK: - Drawing the overlays

    /// The click ripple at one instant, drawn at the size the shared metrics ask for.
    ///
    /// The metrics are fractions of the *recorded* area's shortest edge, so the ripple is
    /// the same size relative to the content whatever the recording's resolution — then
    /// scaled by the camera, because a ripple belongs to the scene and zooms with it.
    private func ripple(progress: Double, scale: CGFloat) -> CGImage? {
        let reference = min(plan.sourceSize.width, plan.sourceSize.height) * scale
        let radius = reference * ClickRippleMetrics.radiusFraction(at: progress)
        let stroke = reference * ClickRippleMetrics.strokeFraction(at: progress)
        let opacity = ClickRippleMetrics.opacity(at: progress)
        guard radius > 0.5, opacity > 0.001 else { return nil }

        let side = Int((radius * 2 + stroke * 2).rounded(.up))
        return BitmapCanvas.image(width: side, height: side) { context in
            let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
            context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: opacity)
            context.setLineWidth(stroke)
            context.strokeEllipse(in: CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }

    /// The keystroke caption showing at `time`, and where it goes.
    private func caption(at time: TimeInterval) -> (image: CGImage?, placement: CGRect)? {
        // Binary-searched and walked back, rather than filtering every chord in the
        // recording into a fresh array on every frame (docs/10 R1.2).
        let recent = TimeSortedLookup.elements(
            within: ClickRippleMetrics.captionDuration,
            endingAt: time,
            in: telemetry.keystrokes,
            key: \.time
        )
        guard let last = recent.last else { return nil }
        let opacity = ClickRippleMetrics.captionOpacity(elapsed: time - last.time)
        guard opacity > 0.001 else { return nil }

        // The last few chords rather than only the newest: somebody demonstrating ⌘⇧4 hits
        // three keys in half a second, and a caption that replaces itself each time shows
        // the last one and implies the others never happened.
        let text = recent.suffix(3).map(\.caption).joined(separator: "  ")
        let fontSize = max(plan.outputSize.height * 0.035, 12)
        guard let image = CaptionCanvas.image(text: text, fontSize: fontSize, opacity: opacity) else {
            return nil
        }
        let margin = plan.outputSize.height * 0.06
        let placement = CGRect(
            x: (plan.outputSize.width - CGFloat(image.width)) / 2,
            y: plan.outputSize.height - CGFloat(image.height) - margin,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        return (image, placement)
    }

    // MARK: - The camera bubble

    /// The webcam, cropped square-ish, rounded and placed.
    private func bubble(_ camera: CIImage, over base: CIImage) -> CIImage {
        let rect = edit.camera.frame(in: plan.outputSize)
        guard rect.width > 1, rect.height > 1, camera.extent.width > 0, camera.extent.height > 0 else {
            return base
        }

        // Aspect-fill: a webcam is 16:9 and the bubble is usually round, so fitting it
        // would letterbox a circle — which looks like a bug rather than a choice.
        let scale = max(rect.width / camera.extent.width, rect.height / camera.extent.height)
        let scaled = camera
            .transformed(by: CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let inset = CGRect(
            x: (scaled.extent.width - rect.width) / 2,
            y: (scaled.extent.height - rect.height) / 2,
            width: rect.width,
            height: rect.height
        )
        let cropped = scaled
            .cropped(to: inset)
            .transformed(by: CGAffineTransform(translationX: -inset.minX, y: -inset.minY))

        let radius = edit.camera.cornerRadius(in: plan.outputSize)
        let masked = mask(cropped, size: rect.size, radius: radius)
        return composite(masked, into: rect, over: base)
    }

    /// Rounds an image's corners.
    ///
    /// A drawn mask rather than `CIRoundedRectangleGenerator`, which is macOS 14+ only in
    /// the shape Kadr needs and produces a slightly different curve than the editor's own
    /// rounded rects — the bubble would not match the card it was dragged from.
    private func mask(_ image: CIImage, size: CGSize, radius: CGFloat) -> CIImage {
        guard radius > 0.5 else { return image }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let maskImage = BitmapCanvas.image(width: width, height: height, action: { context in
                  context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                  context.addPath(CGPath(
                      roundedRect: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                      cornerWidth: min(radius, size.width / 2),
                      cornerHeight: min(radius, size.height / 2),
                      transform: nil
                  ))
                  context.fillPath()
              })
        else {
            return image
        }
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputMaskImageKey: CIImage(cgImage: maskImage),
            kCIInputBackgroundImageKey: CIImage.empty()
        ])
    }
}

// MARK: - Drawing helpers

/// A premultiplied ARGB bitmap to draw one overlay into.
///
/// Its own type because every overlay wants the same eight lines of `CGContext` setup, and
/// the one place this went wrong before was a hand-rolled buffer passed to `CGContext` as
/// `data: &bytes` — which is undefined behaviour the moment the call returns (docs/07).
enum BitmapCanvas {
    static func image(width: Int, height: Int, action: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: bytesPerRow * height)

        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setShouldAntialias(true)
        action(context)
        return context.makeImage()
    }
}

/// The keystroke caption's pill.
enum CaptionCanvas {
    static func image(text: String, fontSize: CGFloat, opacity: Double) -> CGImage? {
        guard !text.isEmpty else { return nil }
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(
                red: 1, green: 1, blue: 1, alpha: opacity
            )
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding = fontSize * 0.6
        let width = Int((bounds.width + padding * 2).rounded(.up))
        let height = Int((bounds.height + padding * 1.2).rounded(.up))

        return BitmapCanvas.image(width: width, height: height) { context in
            let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.65 * opacity)
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: rect.height / 2,
                cornerHeight: rect.height / 2,
                transform: nil
            ))
            context.fillPath()
            context.textPosition = CGPoint(x: padding - bounds.minX, y: padding * 0.6 - bounds.minY)
            CTLineDraw(line, context)
        }
    }
}

/// Decoding the recorded cursor artwork.
enum CursorArtwork {
    /// A `CGImage` from PNG bytes.
    ///
    /// `CGImageSource` rather than CoreImage: the result is wanted as a `CGImage` to be
    /// composited many times, and going through `CIImage` would mean a render and a
    /// readback per cursor for no gain.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// The one CoreImage context the studio renders through.
///
/// Shared because a `CIContext` carries compiled kernels and a texture cache, and building
/// one per frame is most of the cost of a frame. Public so the editor's preview renders
/// through the same one — a second context would produce the same pixels, eventually, after
/// compiling the same kernels again.
public enum StudioRenderContext {
    public static let shared = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
    ])
}
