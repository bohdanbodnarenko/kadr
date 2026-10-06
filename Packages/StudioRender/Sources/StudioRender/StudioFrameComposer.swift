import CoreGraphics
import CoreImage
import Foundation
import os
import Shared
import StudioSession

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
    public let transcript: Transcript

    /// Recorded pixels per point (docs/11 S0.5).
    ///
    /// The cursor artwork is the only thing in the sidecar measured in points, because
    /// `NSCursor` is; everything else — the pointer path, the click positions, the frame —
    /// is already in the recording's own pixels.
    private let pointPixelScale: CGFloat

    private let reconstruction: CursorReconstruction
    private let cursorPath: [CGPoint]
    private let cursorImages: [CGImage?]
    private let frameDuration: TimeInterval
    /// Decoded wallpaper, or nil when the canvas is a colour fill or there is no file.
    let wallpaper: CIImage?
    let captionCues: [CaptionCue]
    let cachedCardMask: CIImage?
    /// The fill behind the card with the card's shadow already on it, rendered once.
    ///
    /// Nil when the frame has no card chrome. Everything in it depends on the plan and the
    /// edit alone, and CoreImage cannot be relied on to remember it between frames — the
    /// shared context is built with `cacheIntermediates: false` — so leaving it as a recipe
    /// meant a full-canvas gradient rasterised on the CPU and a full-canvas Gaussian blur on
    /// the GPU for every frame of every export. Baked here, a frame samples one texture.
    let cachedGround: CIImage?
    /// The camera bubble's mask, shadow and hairline, drawn once (docs/09 U3.4).
    let cachedBubble: BubbleChrome?
    /// Rasterised captions, so a caption that stays on screen for eighty frames is laid
    /// out and drawn once rather than eighty times.
    let overlayCache: OverlayImageCache

    /// Opaque black the size of the output, to put letterbox bars on.
    ///
    /// Stored rather than computed: it is a generator and a crop, which is cheap, but it is
    /// the same generator and crop on every frame and there is no reason to build it twice.
    private let backdrop: CIImage

    /// The most the camera may enlarge an overlay.
    ///
    /// Overlays scale with the camera, because a cursor and a ripple are part of the scene
    /// — a pointer that stayed the same size through a zoom would slide across the picture
    /// like a sticker on the lens. But only so far: at 4× an unclamped system cursor
    /// becomes a dinner plate, which is its own kind of wrong.
    static let maximumOverlayScale: CGFloat = 2.5

    /// Per-frame composition, for PRD §8's export budget (CLAUDE.md rule 8).
    ///
    /// Building the recipe is CPU work that happens before CoreImage renders anything, and
    /// the caption rasterisation inside it is the part that used to dominate.
    static let signposter = OSSignposter(logger: KadrLog.logger(.recording))

    public init(
        plan: StudioRenderPlan,
        edit: StudioEdit,
        telemetry: InputTelemetry,
        transcript: Transcript = Transcript(),
        frameRate: Int = 60,
        // Two, not one: a Mac with no Retina display is now the unusual case, and a
        // session written before the manifest carried a real scale is far more likely to
        // have come from a Retina machine than not. `CaptureManifest` decodes the same
        // default for the same reason.
        pointPixelScale: CGFloat = 2,
        spring: MotionSpring? = nil,
        wallpaper: CGImage? = nil
    ) {
        self.plan = plan
        self.edit = edit
        self.pointPixelScale = max(pointPixelScale, 0.0001)
        // Captions say what the user corrected, not what the engine heard (docs/18 Phase 4).
        self.transcript = transcript.applying(corrections: edit.transcriptCorrections)
        // Rebased once, here (docs/10 R0.2). The sidecar is written in source time and
        // every method below is called with an edited-time playhead; converting at the
        // boundary is what stops the two being confused anywhere past it, and is why the
        // preview and the export agree by construction rather than by both remembering.
        self.telemetry = telemetry.rebased(to: edit.clips)
        frameDuration = 1.0 / Double(max(frameRate, 1))
        reconstruction = CursorReconstruction(spring: spring ?? MotionSpring(edit.cursorSmoothing))
        cursorPath = reconstruction.path(for: self.telemetry, duration: plan.duration)
        // Decoded once. A cursor PNG is a few hundred bytes and there are rarely more than
        // a dozen of them, but decoding one per frame is a decode per frame.
        cursorImages = self.telemetry.cursors.map { CursorArtwork.decode($0.pngData) }
        self.wallpaper = wallpaper.map { CIImage(cgImage: $0) }
        captionCues = CaptionExport.cues(from: transcript, timeline: edit.clips)
        backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(origin: .zero, size: plan.outputSize))
        cachedCardMask = Self.makeCardMask(plan: plan, edit: edit)
        cachedGround = Self.usesCardChrome(plan: plan, edit: edit)
            ? Self.makeGround(plan: plan, edit: edit, wallpaper: self.wallpaper)
            : nil
        cachedBubble = edit.camera.isVisible ? BubbleChrome(plan: plan, camera: edit.camera) : nil
        overlayCache = OverlayImageCache()
    }

    /// `source` scaled so its extent is the recording's own pixel size.
    ///
    /// Every crop the composer takes is in recorded pixels, because that is what the plan
    /// and the telemetry speak. A caller that decodes the screen at a lower resolution — a
    /// preview asking the decoder for a half-size frame, or a compositor handed whatever
    /// the track's natural size is — would otherwise have its frame cropped as though it
    /// were full size, and show the top-left quarter of the recording blown up.
    ///
    /// A transform rather than a resample: CoreImage folds it into the crop and scale that
    /// follow, so the only cost is one more matrix in the recipe. The identity when the
    /// sizes already agree, which is the export's case. Camera frames need none of this —
    /// the bubble aspect-fills whatever it is given.
    public func normalizedSource(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let target = plan.sourceSize
        guard !extent.isInfinite, extent.width > 0, extent.height > 0,
              target.width > 0, target.height > 0,
              extent.size != target
        else {
            return image
        }
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(
                scaleX: target.width / extent.width,
                y: target.height / extent.height
            ))
    }

    /// The output frame at `time`.
    ///
    /// Safe to call from several threads at once — an `AVVideoCompositing` implementation
    /// does. Everything the composer holds is immutable except its caption cache, which is
    /// behind a lock.
    ///
    /// - Parameters:
    ///   - source: the screen frame. Its extent is normalised to the recording's pixel size
    ///     first (`normalizedSource(_:)`), so a downscaled decode is fine.
    ///   - camera: the webcam frame, if there is one for this instant.
    public func frame(at time: TimeInterval, source: CIImage, camera: CIImage?) -> CIImage {
        let interval = Self.signposter.beginInterval("studio.compose")
        defer { Self.signposter.endInterval("studio.compose", interval) }
        var image = viewport(at: time, source: normalizedSource(source))
        image = overlays(at: time, over: image)
        if let ground = cachedGround {
            image = clipToCard(image.composited(over: backdrop))
            image = image.composited(over: ground)
        }
        if let camera, edit.camera.isVisible {
            image = bubble(camera, over: image)
        }
        if cachedGround == nil {
            // Over opaque black, so a letterboxed `.fit` frame has bars rather than holes.
            image = image.composited(over: backdrop)
        }
        // Cropped last and always: a composite whose extent has grown past the frame — a
        // ripple at the edge, a bubble flush to the corner — writes a pixel buffer with a
        // silently shifted origin, and the whole video comes out offset.
        return image.cropped(to: CGRect(origin: .zero, size: plan.outputSize))
    }

    // MARK: - The camera

    /// The source frame cropped and scaled to the viewport, with motion blur if it is moving.
    private func viewport(at time: TimeInterval, source: CIImage) -> CIImage {
        let blur = MotionBlurPlan.plan(isMoving: plan.isMoving(at: time), intensity: edit.motionBlur)
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
        // Fitted and centred rather than scaled by width (docs/11 S0.5). The vertical
        // offset is the same number in either origin convention because the letterbox is
        // symmetric, which is the only reason this can use `origin` directly.
        let presentation = plan.presentation(for: rect)
        return cropped
            .transformed(by: CGAffineTransform(translationX: -cropped.extent.minX, y: -cropped.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: presentation.scale, y: presentation.scale))
            .transformed(by: CGAffineTransform(
                translationX: presentation.origin.x,
                y: presentation.origin.y
            ))
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
        // Looked up once for the whole frame. Every overlay needs the same answer, and
        // `sourceRect(at:)` walks the integrated viewport table to produce it.
        let viewport = plan.sourceRect(at: time)
        let scale = min(plan.presentation(for: viewport).scale, Self.maximumOverlayScale)

        if edit.showsClicks, let press = cursor.flatMap(Press.init) {
            image = compositing(
                ripple(progress: press.progress, scale: scale),
                at: press.origin,
                in: viewport,
                over: image
            )
        }
        if edit.showsCursor, let cursor {
            image = compositingCursor(cursor, scale: scale, in: viewport, over: image)
        }
        if edit.showsKeystrokes, let caption = caption(at: time) {
            image = compositing(caption.image, at: nil, in: viewport, over: image, placement: caption.placement)
        }
        if edit.showsCaptions, let caption = speechCaption(at: time) {
            image = compositing(caption.image, at: nil, in: viewport, over: image, placement: caption.placement)
        }
        return image
    }

    /// Draws the recorded cursor artwork at the reconstructed position.
    private func compositingCursor(
        _ cursor: ReconstructedCursor,
        scale: CGFloat,
        in viewport: CGRect,
        over base: CIImage
    ) -> CIImage {
        guard let index = cursor.cursorIndex,
              telemetry.cursors.indices.contains(index),
              let artwork = cursorImages[index]
        else {
            return base
        }
        let recorded = telemetry.cursors[index]

        // Points into recorded pixels, then into output pixels (docs/11 S0.5).
        //
        // `NSCursor` measures both its size and its hotspot in points; the footage is in
        // pixels, and on every Retina display there are two of those per point. The
        // conversion was missing entirely — `CaptureManifest.scale` is documented as
        // "pixels per point, so the reconstruction draws a cursor the right size", was
        // written as a hard-coded 1, and was read by nothing — so every Retina export drew
        // a cursor at half size.
        //
        // The hotspot needed the opposite correction: it was being divided by the artwork's
        // own pixels-per-point on the belief that it arrived in pixels, which moved an
        // I-beam's tip up and to the left of the text it was pointing at. Size and hotspot
        // share a unit, so the only conversion either needs is the one applied to both.
        let press: CGFloat = if edit.showsClickPress, let progress = cursor.clickProgress {
            ClickRippleMetrics.pressScale(at: progress)
        } else {
            1
        }
        let drawn = pointPixelScale * scale * press * min(
            max(edit.cursorScale, StudioEdit.minimumCursorScale),
            StudioEdit.maximumCursorScale
        )
        let size = CGSize(width: recorded.size.width * drawn, height: recorded.size.height * drawn)
        guard size.width > 0, size.height > 0 else { return base }

        let hotspot = CGPoint(x: recorded.hotspot.x * drawn, y: recorded.hotspot.y * drawn)
        let topLeft = plan.outputPoint(cursor.position, in: viewport)
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
        in viewport: CGRect,
        over base: CIImage,
        placement: CGRect? = nil
    ) -> CIImage {
        guard let overlay else { return base }
        let rect: CGRect
        if let placement {
            rect = placement
        } else if let sourcePoint {
            let centre = plan.outputPoint(sourcePoint, in: viewport)
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
    func composite(_ overlay: CIImage, into rect: CGRect, over base: CIImage) -> CIImage {
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
}

// MARK: - Drawing helpers

/// A premultiplied ARGB bitmap to draw one overlay into.
///
/// Its own type because every overlay wants the same eight lines of `CGContext` setup, and
/// the one place this went wrong before was a hand-rolled buffer passed to `CGContext` as
/// `data: &bytes` — which is undefined behaviour the moment the call returns (docs/07).
enum BitmapCanvas {
    /// Device RGB, as it always has been — made once rather than once per overlay.
    private static let colourSpace = CGColorSpaceCreateDeviceRGB()

    /// Draws into a fresh, cleared bitmap and hands back the picture.
    ///
    /// The context allocates its own memory. The previous version allocated a buffer,
    /// drew into it and then called `makeImage()`, which copies — two full allocations per
    /// overlay, and at 4K a full-canvas plate is 33 MB each. A context that owns its
    /// storage makes an image that shares it copy-on-write, and since the context is
    /// thrown away straight after, the copy never happens.
    static func image(width: Int, height: Int, action: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        // Explicitly transparent. CoreGraphics does zero the memory it allocates, but that
        // is an implementation detail, and a plate with garbage in its corners is the kind
        // of bug that only shows on somebody else's machine.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(true)
        action(context)
        return context.makeImage()
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
        .workingColorSpace: sRGB
    ])

    /// sRGB, made once. The export used to look it up by name for every frame it wrote.
    public static let sRGB: CGColorSpace = .init(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}
