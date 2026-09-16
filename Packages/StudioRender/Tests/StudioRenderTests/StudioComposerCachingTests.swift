import CoreGraphics
import CoreImage
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// What the composer now draws once instead of every frame (docs/09 U3.2–U3.5).
///
/// Caching is only worth having if nobody can tell it is there. So each cached picture is
/// held against one drawn the old way — a caption straight from `CaptionCanvas`, a shadow on
/// a canvas-sized plate — and the composer is hammered from many tasks at once, because an
/// `AVVideoCompositing` implementation calls it exactly like that.
@Suite("Studio composer caching")
struct StudioComposerCachingTests {
    private let sourceSize = CGSize(width: 400, height: 200)

    // MARK: - Fixtures

    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, size: CGSize) throws -> CIImage {
        let image = try #require(BitmapCanvas.image(width: Int(size.width), height: Int(size.height)) { context in
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
        })
        return CIImage(cgImage: image)
    }

    /// Left half red, right half blue.
    private func halved(size: CGSize) throws -> CIImage {
        let image = try #require(BitmapCanvas.image(width: Int(size.width), height: Int(size.height)) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        })
        return CIImage(cgImage: image)
    }

    /// A busy edit: card chrome on a gradient, a round bubble, keystrokes and captions.
    private func busyEdit() -> StudioEdit {
        var edit = StudioEdit.untouched(duration: 4)
        edit.canvas = .presenter
        edit.showsKeystrokes = true
        edit.showsCaptions = true
        edit.showsCursor = true
        edit.showsClicks = true
        edit.camera = CameraBubble(placement: .bottomTrailing, sizeFraction: 0.3, roundness: 1, isVisible: true)
        return edit
    }

    private func busyTelemetry() -> InputTelemetry {
        InputTelemetry(
            pointer: stride(from: 0.0, through: 4, by: 0.05).map {
                PointerSample(time: $0, position: CGPoint(x: 50 + $0 * 60, y: 100))
            },
            clicks: [ClickEvent(time: 0.5, position: CGPoint(x: 80, y: 100))],
            keystrokes: [
                KeystrokeEvent(time: 0.2, caption: "⌘S"),
                KeystrokeEvent(time: 0.4, caption: "⇧⌘4"),
                KeystrokeEvent(time: 2.0, caption: "Return")
            ]
        )
    }

    private let transcript = Transcript(words: [
        TranscriptWord(text: "Hello", start: 0, end: 0.4),
        TranscriptWord(text: "cached", start: 0.5, end: 1.0),
        TranscriptWord(text: "world", start: 1.1, end: 1.6)
    ])

    /// RGBA bytes of an image, top row first.
    private func bytes(of image: CIImage, size: CGSize) throws -> [UInt8] {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(StudioRenderContext.shared.createCGImage(
            image,
            from: CGRect(origin: .zero, size: size),
            format: .RGBA8,
            colorSpace: StudioRenderContext.sRGB
        ))
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return pixels
    }

    private func bytes(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func largestDifference(_ first: [UInt8], _ second: [UInt8]) -> Int {
        zip(first, second).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    // MARK: - Captions

    @Test("A cached keystroke caption is the caption drawn fresh")
    func keystrokeCaptionMatchesFresh() throws {
        let edit = busyEdit()
        let composer = StudioFrameComposer(
            plan: StudioRenderPlan(edit: edit, sourceSize: sourceSize),
            edit: edit,
            telemetry: busyTelemetry()
        )
        // Inside the fade, where the opacity is quantised.
        for time in [0.45, 0.9, 1.3, 1.5, 1.7] {
            let first = try #require(composer.caption(at: time)?.image)
            let again = try #require(composer.caption(at: time)?.image)
            #expect(first === again, "a second ask at \(time) drew again")

            let recent = composer.telemetry.keystrokes.filter { $0.time <= time && time - $0.time <= 1.4 }
            let last = try #require(recent.last)
            let reference = min(composer.plan.cardRect.width, composer.plan.cardRect.height)
            let fresh = try #require(CaptionCanvas.image(
                text: recent.suffix(3).map(\.caption).joined(separator: "  "),
                fontSize: max(reference * 0.035 * edit.keystrokeScale, 12),
                opacity: OverlayImageCache.quantised(ClickRippleMetrics.captionOpacity(elapsed: time - last.time)),
                appearance: edit.keystrokeAppearance
            ))
            #expect(bytes(of: first) == bytes(of: fresh), "the cached caption at \(time) differs")
        }
    }

    @Test("A cached speech caption is the caption drawn fresh")
    func speechCaptionMatchesFresh() throws {
        let edit = busyEdit()
        let composer = StudioFrameComposer(
            plan: StudioRenderPlan(edit: edit, sourceSize: sourceSize),
            edit: edit,
            telemetry: InputTelemetry(),
            transcript: transcript
        )
        let cached = try #require(composer.speechCaption(at: 0.7)?.image)
        #expect(composer.speechCaption(at: 0.7)?.image === cached)

        let uncached = try #require(StudioFrameComposer(
            plan: StudioRenderPlan(edit: edit, sourceSize: sourceSize),
            edit: edit,
            telemetry: InputTelemetry(),
            transcript: transcript
        ).speechCaption(at: 0.7)?.image)
        #expect(uncached !== cached)
        #expect(bytes(of: uncached) == bytes(of: cached))
    }

    @Test("Opacity is quantised to sixty-fourths and clamped")
    func opacityQuantisation() {
        let cases: [(input: Double, expected: Double)] = [
            (0, 0), (1, 1), (0.5, 0.5), (0.92, 59.0 / 64), (0.0001, 0),
            (1.3, 1), (-0.2, 0), (0.999, 1), (1.0 / 64 + 0.001, 1.0 / 64)
        ]
        for (input, expected) in cases {
            #expect(OverlayImageCache.quantised(input) == expected, "\(input)")
        }
    }

    @Test("The caption cache stays within its count and serves the most recent entries")
    func cacheIsBoundedByCount() throws {
        let cache = OverlayImageCache()
        let total = OverlayImageCache.capacity + 16
        let keys = (0 ..< total).map { CaptionKey(text: "key \($0)", fontSize: 14, opacity: 1) }
        var drawn: [CGImage] = []
        for key in keys {
            try drawn.append(#require(cache.caption(key)))
        }
        #expect(cache.usage.count == OverlayImageCache.capacity)
        #expect(cache.caption(keys[total - 1]) === drawn[total - 1], "the newest entry was evicted")
        #expect(cache.caption(keys[0]) !== drawn[0], "an entry beyond the capacity was kept")
    }

    @Test("The caption cache stays within its byte budget but keeps the newest picture")
    func cacheIsBoundedByBytes() throws {
        let cache = OverlayImageCache()
        // Wide, tall pills: a few megabytes each.
        let keys = (0 ..< 24).map { index in
            CaptionKey(text: String(repeating: "W", count: 40) + "\(index)", fontSize: 180, opacity: 1)
        }
        var drawn: [CGImage] = []
        for key in keys {
            try drawn.append(#require(cache.caption(key)))
        }
        let usage = cache.usage
        #expect(usage.bytes <= OverlayImageCache.byteLimit, "\(usage.bytes) bytes held")
        #expect(usage.count < keys.count)
        #expect(cache.caption(keys[23]) === drawn[23])

        let huge = CaptionKey(text: String(repeating: "W", count: 400), fontSize: 400, opacity: 1)
        let picture = try #require(cache.caption(huge))
        #expect(cache.caption(huge) === picture, "a picture over the whole budget was not kept")
        #expect(cache.usage.count == 1)
    }

    // MARK: - Static chrome

    /// The card shadow the old way: a plate the size of the whole canvas.
    private func legacyGround(plan: StudioRenderPlan, edit: StudioEdit) throws -> CIImage {
        let canvas = plan.outputSize
        let strength = edit.canvas.shadow
        let shortest = min(canvas.width, canvas.height)
        let card = plan.cardRect
        let flipped = CGRect(
            x: card.minX,
            y: canvas.height - card.maxY - shortest * 0.016 * strength,
            width: card.width,
            height: card.height
        )
        let radius = plan.cardCornerRadius
        let plate = try #require(BitmapCanvas.image(width: Int(canvas.width), height: Int(canvas.height)) { context in
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.55 * strength)
            context.addPath(CGPath(
                roundedRect: flipped,
                cornerWidth: min(radius, flipped.width / 2),
                cornerHeight: min(radius, flipped.height / 2),
                transform: nil
            ))
            context.fillPath()
        })
        let shadow = CIImage(cgImage: plate)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: shortest * 0.045 * strength])
            .cropped(to: CGRect(origin: .zero, size: canvas))
        let backdrop = StudioFrameComposer.makeCanvasBackdrop(plan: plan, edit: edit, wallpaper: nil)
        return shadow.composited(over: backdrop)
    }

    @Test("The baked backdrop and shadow match the live recipe", arguments: [
        StudioCanvas.presenter,
        StudioCanvas.paper,
        StudioCanvas(paddingFraction: 0.2, cornerRadiusFraction: 0.12, shadow: 1, background: .none),
        StudioCanvas(
            paddingFraction: 0.01,
            cornerRadiusFraction: 0.05,
            shadow: 0.8,
            background: .gradient(StudioGradient(from: .white, to: .graphite, angleDegrees: 33))
        )
    ])
    func bakedGroundMatches(canvas: StudioCanvas) throws {
        var edit = StudioEdit.untouched(duration: 2)
        edit.canvas = canvas
        let plan = StudioRenderPlan(edit: edit, sourceSize: CGSize(width: 640, height: 360))
        let composer = StudioFrameComposer(plan: plan, edit: edit, telemetry: InputTelemetry())
        let baked = try bytes(of: #require(composer.cachedGround), size: plan.outputSize)
        let live = try bytes(of: legacyGround(plan: plan, edit: edit), size: plan.outputSize)

        // Nearly always within a level everywhere. Not always: under a full parallel suite
        // CoreImage's large-radius Gaussian blur now and then comes out differently from the
        // same recipe drawn a moment earlier — the live recipe disagrees with itself just as
        // often, by up to a few dozen levels in single pixels — so the check is on the
        // average. A missing shadow moves it by seven levels or more; the noise by well
        // under a tenth.
        let mean = Double(zip(baked, live).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(baked.count)
        #expect(mean < 0.25, "the baked ground is \(mean) levels off the live one on average")
    }

    @Test("The card mask covers the card and nothing else")
    func boundedCardMask() throws {
        var edit = StudioEdit.untouched(duration: 2)
        edit.canvas = .presenter
        let plan = StudioRenderPlan(edit: edit, sourceSize: CGSize(width: 640, height: 360))
        let mask = try #require(StudioFrameComposer.makeCardMask(plan: plan, edit: edit))
        let canvas = CGRect(origin: .zero, size: plan.outputSize)
        #expect(canvas.contains(mask.extent))
        #expect(mask.extent.width < canvas.width, "the mask is still canvas-sized")

        let card = plan.cardRect
        let pixels = try bytes(of: mask.composited(over: CIImage(color: .black).cropped(to: canvas)), size: canvas.size)
        let width = Int(canvas.width)
        func red(_ x: Int, _ y: Int) -> UInt8 {
            pixels[(y * width + x) * 4]
        }
        #expect(red(Int(card.midX), Int(card.midY)) == 255)
        #expect(red(2, 2) == 0)
    }

    @Test("The bubble shadow on a small plate matches the canvas-sized one")
    func bubbleShadowMatches() throws {
        let canvas = CGSize(width: 640, height: 360)
        for placement in [BubblePlacement.bottomTrailing, .topLeading, .centre] {
            let camera = CameraBubble(placement: placement, sizeFraction: 0.35, marginFraction: 0, roundness: 0.6)
            var edit = StudioEdit.untouched(duration: 2)
            edit.camera = camera
            let plan = StudioRenderPlan(edit: edit, sourceSize: canvas)
            let chrome = try #require(BubbleChrome(plan: plan, camera: camera))
            let shadow = try #require(chrome.shadow)

            let rect = camera.frame(in: canvas)
            let radius = camera.cornerRadius(in: canvas)
            let shortest = min(canvas.width, canvas.height)
            let flipped = CGRect(
                x: rect.minX,
                y: canvas.height - rect.maxY - shortest * 0.009,
                width: rect.width,
                height: rect.height
            )
            let plate = try #require(BitmapCanvas
                .image(width: Int(canvas.width), height: Int(canvas.height)) { context in
                    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.35)
                    context.addPath(CGPath(
                        roundedRect: flipped,
                        cornerWidth: min(radius, flipped.width / 2),
                        cornerHeight: min(radius, flipped.height / 2),
                        transform: nil
                    ))
                    context.fillPath()
                })
            let legacy = CIImage(cgImage: plate)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: shortest * 0.022])
                .cropped(to: CGRect(origin: .zero, size: canvas))

            let white = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: canvas))
            let difference = try largestDifference(
                bytes(of: shadow.composited(over: white), size: canvas),
                bytes(of: legacy.composited(over: white), size: canvas)
            )
            #expect(difference <= 1, "\(placement): the shadow moved by \(difference) levels")
        }
    }

    // MARK: - Concurrency

    /// An `AVVideoCompositing` implementation calls `frame(at:)` from several threads at
    /// once. Every result has to be the one a lone caller would have got.
    @Test("Composing from many tasks at once gives the same frames as composing serially")
    func concurrentFramesMatchSerial() async throws {
        let edit = busyEdit()
        let composer = StudioFrameComposer(
            plan: StudioRenderPlan(edit: edit, sourceSize: sourceSize),
            edit: edit,
            telemetry: busyTelemetry(),
            transcript: transcript
        )
        let size = composer.plan.outputSize
        let source = try halved(size: sourceSize)
        let camera = try solid(0, 1, 0, size: CGSize(width: 160, height: 90))
        let times = stride(from: 0.0, to: 3, by: 0.05).map(\.self)

        var serial: [Int: [UInt8]] = [:]
        for (index, time) in times.enumerated() {
            serial[index] = try bytes(of: composer.frame(at: time, source: source, camera: camera), size: size)
        }

        let concurrent = try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { group in
            for round in 0 ..< 4 {
                for (index, time) in times.enumerated() where (index + round).isMultiple(of: 2) || round > 1 {
                    group.addTask {
                        let image = composer.frame(at: time, source: source, camera: camera)
                        return try (index, bytes(of: image, size: size))
                    }
                }
            }
            var results: [(Int, [UInt8])] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
        #expect(concurrent.count > times.count)
        for (index, pixels) in concurrent {
            #expect(pixels == serial[index], "frame \(index) differed when composed concurrently")
        }
    }
}
