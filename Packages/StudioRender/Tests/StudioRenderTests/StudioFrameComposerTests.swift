import CoreGraphics
import CoreImage
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// Assembling one studio frame (docs/09 U3.2, U3.3).
///
/// Against real pixels rather than against the calls the composer makes. Every bug this
/// code has had in other projects — a crop taken in the wrong origin, a cursor drawn at its
/// top-left instead of its hotspot, a bubble in the wrong corner — is invisible to a test
/// that checks which filters were applied and obvious to one that reads a pixel.
@Suite("Studio frame composer")
struct StudioFrameComposerTests {
    // MARK: - Fixtures

    private let sourceSize = CGSize(width: 400, height: 200)

    /// A frame whose left half is red and right half is blue, in top-left terms.
    private func halvedSource() throws -> CIImage {
        let image = try #require(BitmapCanvas.image(width: 400, height: 200) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        })
        return CIImage(cgImage: image)
    }

    /// A frame whose top half is red and bottom half is blue, in top-left terms.
    ///
    /// `BitmapCanvas` draws bottom-up like every `CGContext`, so the rect that ends up at
    /// the *top* of the image is the one with the higher y. Getting this backwards in the
    /// fixture would make a flipped renderer look correct.
    private func stackedSource() throws -> CIImage {
        let image = try #require(BitmapCanvas.image(width: 400, height: 200) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 100, width: 400, height: 100))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        })
        return CIImage(cgImage: image)
    }

    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, size: CGSize) throws -> CIImage {
        let image = try #require(BitmapCanvas.image(width: Int(size.width), height: Int(size.height)) { context in
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
        })
        return CIImage(cgImage: image)
    }

    private func edit(
        zooms: [ZoomCue] = [],
        duration: TimeInterval = 4,
        showsCursor: Bool = false,
        showsClicks: Bool = false,
        showsKeystrokes: Bool = false,
        camera: CameraBubble = CameraBubble(isVisible: false)
    ) -> StudioEdit {
        var edit = StudioEdit.untouched(duration: duration)
        edit.zooms = zooms
        edit.showsCursor = showsCursor
        edit.showsClicks = showsClicks
        edit.showsKeystrokes = showsKeystrokes
        edit.camera = camera
        return edit
    }

    private func composer(_ edit: StudioEdit, telemetry: InputTelemetry = InputTelemetry()) -> StudioFrameComposer {
        StudioFrameComposer(
            plan: StudioRenderPlan(edit: edit, sourceSize: sourceSize),
            edit: edit,
            telemetry: telemetry
        )
    }

    // MARK: - Reading the result

    /// One pixel's colour.
    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    /// A rendered frame, sampled in top-left coordinates.
    private struct Frame {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        /// The colour at a top-left point.
        func at(_ x: Int, _ y: Int) -> Pixel {
            let offset = (y * width + x) * 4
            guard offset + 2 < pixels.count else { return Pixel(red: 0, green: 0, blue: 0) }
            return Pixel(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2])
        }

        var checksum: Int {
            // A cheap content hash. Positional, so two frames with the same colours in
            // different places do not collide — which is the whole point of comparing them.
            pixels.enumerated().reduce(into: 0) { total, entry in
                total = (total &* 31 &+ Int(entry.element) &+ entry.offset % 7) % 1_000_000_007
            }
        }
    }

    /// Renders a composed frame into RGBA bytes, top row first.
    private func render(_ image: CIImage, size: CGSize) throws -> Frame {
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
        let cgImage = try #require(StudioRenderContext.shared.createCGImage(image, from: image.extent))
        // No flip: a bitmap context's first row in memory is already the top row of the
        // image it draws. Flipping here would make row zero the bottom and quietly turn
        // every "the top should be red" assertion in this file into its opposite.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return Frame(pixels: pixels, width: width, height: height)
    }

    // MARK: - The viewport

    @Test("An untouched frame comes out the same size and the same way up")
    func untouchedFrame() throws {
        let composed = try composer(edit()).frame(at: 0, source: halvedSource(), camera: nil)
        #expect(composed.extent.width == 400)
        #expect(composed.extent.height == 200)

        let frame = try render(composed, size: sourceSize)
        #expect(frame.at(50, 100).red > 200, "the left half should still be red")
        #expect(frame.at(350, 100).blue > 200, "the right half should still be blue")
    }

    /// The flip is the single easiest thing to get wrong: CoreImage's origin is bottom-left
    /// and everything Kadr records is top-left, so a renderer that forgets produces a
    /// perfectly plausible upside-down video.
    @Test("The frame is not vertically flipped")
    func notFlipped() throws {
        let composed = try composer(edit()).frame(at: 0, source: stackedSource(), camera: nil)
        let frame = try render(composed, size: sourceSize)
        #expect(frame.at(200, 20).red > 200, "the top should be red")
        #expect(frame.at(200, 180).blue > 200, "the bottom should be blue")
    }

    @Test("A zoom into the left half shows only the left half")
    func zoomCropsCorrectly() throws {
        let cue = ZoomCue(start: 0, duration: 4, magnification: 3, anchor: .fixed(CGPoint(x: 60, y: 100)))
        let composed = try composer(edit(zooms: [cue])).frame(at: 3.5, source: halvedSource(), camera: nil)
        let frame = try render(composed, size: sourceSize)

        // Zoomed 3× into the red half, every corner is red.
        for point in [(10, 10), (390, 10), (10, 190), (390, 190), (200, 100)] {
            let colour = frame.at(point.0, point.1)
            #expect(colour.red > 200, "expected red at \(point), got \(colour)")
            #expect(colour.blue < 60, "expected no blue at \(point), got \(colour)")
        }
    }

    @Test("A zoom into the right half shows only the right half")
    func zoomCropsRightward() throws {
        let cue = ZoomCue(start: 0, duration: 4, magnification: 3, anchor: .fixed(CGPoint(x: 340, y: 100)))
        let composed = try composer(edit(zooms: [cue])).frame(at: 3.5, source: halvedSource(), camera: nil)
        let frame = try render(composed, size: sourceSize)
        #expect(frame.at(200, 100).blue > 200, "a zoom to the right half should be blue")
    }

    // MARK: - Overlays

    /// A four-pixel white square with its hotspot in the middle, so a hotspot mistake shows
    /// up as the mark being two pixels off rather than not being there.
    private func cursorTelemetry(at position: CGPoint) throws -> InputTelemetry {
        let artwork = try #require(BitmapCanvas.image(width: 20, height: 20) { context in
            context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        })
        let png = try #require(pngData(artwork))
        return InputTelemetry(
            pointer: [
                PointerSample(time: 0, position: position, cursorIndex: 0),
                PointerSample(time: 4, position: position, cursorIndex: 0)
            ],
            cursors: [CursorImage(pngData: png, hotspot: CGPoint(x: 10, y: 10), size: CGSize(width: 20, height: 20))]
        )
    }

    private func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    @Test("The cursor is drawn at its reconstructed position")
    func cursorIsDrawn() throws {
        let telemetry = try cursorTelemetry(at: CGPoint(x: 300, y: 100))
        let composed = try composer(edit(showsCursor: true), telemetry: telemetry)
            .frame(at: 3.5, source: halvedSource(), camera: nil)
        let frame = try render(composed, size: sourceSize)

        #expect(frame.at(300, 100).green > 180, "no cursor where the pointer was")
        #expect(frame.at(100, 100).green < 60, "the cursor was drawn somewhere it should not be")
    }

    @Test("No cursor is drawn when the edit turns it off")
    func cursorCanBeTurnedOff() throws {
        let telemetry = try cursorTelemetry(at: CGPoint(x: 300, y: 100))
        let composed = try composer(edit(showsCursor: false), telemetry: telemetry)
            .frame(at: 3.5, source: halvedSource(), camera: nil)
        let frame = try render(composed, size: sourceSize)
        #expect(frame.at(300, 100).green < 60)
    }

    /// Overlay tests draw over a flat background rather than the halved one: a ripple is
    /// detected by looking for a channel the background does not have, and a sampling row
    /// that crossed the red/blue boundary would report the boundary as the ripple.
    private func flatSource() throws -> CIImage {
        try solid(1, 0, 0, size: sourceSize)
    }

    @Test("A click ripple appears around the press and fades")
    func rippleIsDrawn() throws {
        var telemetry = try cursorTelemetry(at: CGPoint(x: 200, y: 100))
        telemetry.clicks = [ClickEvent(time: 2, position: CGPoint(x: 200, y: 100))]
        let composed = composer(edit(showsClicks: true), telemetry: telemetry)

        let during = try render(composed.frame(at: 2.1, source: flatSource(), camera: nil), size: sourceSize)
        let after = try render(composed.frame(at: 3.5, source: flatSource(), camera: nil), size: sourceSize)

        // The ripple is a thin white ring a few pixels across, so the check is "any blue
        // at all near the press" rather than a particular pixel: pinning the assertion to
        // one row would make it a test of `radiusFraction`'s current constants, which are
        // tested where they live.
        #expect(whiteness(around: CGPoint(x: 200, y: 100), in: during) > 0, "no ripple near the press")
        #expect(whiteness(around: CGPoint(x: 200, y: 100), in: after) == 0, "the ripple outlived its own duration")
    }

    /// How many pixels near `centre` carry blue, which a red background does not.
    private func whiteness(around centre: CGPoint, in frame: Frame, radius: Int = 25) -> Int {
        var count = 0
        for y in Int(centre.y) - radius ... Int(centre.y) + radius where y >= 0 && y < frame.height {
            for x in Int(centre.x) - radius ... Int(centre.x) + radius where x >= 0 && x < frame.width {
                if frame.at(x, y).blue > 15 {
                    count += 1
                }
            }
        }
        return count
    }

    @Test("A keystroke caption appears and then goes away")
    func captionIsDrawn() throws {
        var telemetry = InputTelemetry()
        telemetry.keystrokes = [KeystrokeEvent(time: 1, caption: "⌘S")]
        let composed = composer(edit(showsKeystrokes: true), telemetry: telemetry)

        let during = try render(composed.frame(at: 1.1, source: flatSource(), camera: nil), size: sourceSize)
        let after = try render(composed.frame(at: 3.5, source: flatSource(), camera: nil), size: sourceSize)

        // The caption's pill is dark and sits near the bottom centre, over red.
        let dim = (150 ... 250).contains { x in during.at(x, 180).red < 150 }
        #expect(dim, "no caption pill near the bottom")
        let stillDim = (150 ... 250).contains { x in after.at(x, 180).red < 150 }
        #expect(!stillDim, "the caption outlived its own duration")
    }

    // MARK: - The camera bubble

    @Test("The bubble lands in the corner it was asked for")
    func bubbleIsPlaced() throws {
        let bubble = CameraBubble(
            placement: .bottomTrailing,
            sizeFraction: 0.4,
            marginFraction: 0.02,
            roundness: 0,
            isVisible: true
        )
        let camera = try solid(0, 1, 0, size: CGSize(width: 160, height: 120))
        let composed = try composer(edit(camera: bubble)).frame(at: 0, source: halvedSource(), camera: camera)
        let frame = try render(composed, size: sourceSize)

        let rect = bubble.frame(in: sourceSize)
        let inside = frame.at(Int(rect.midX), Int(rect.midY))
        #expect(inside.green > 180, "the bubble is not where the layout says, found \(inside)")
        #expect(frame.at(20, 20).red > 200, "the bubble covered the whole frame")
    }

    @Test("A hidden bubble is not drawn even when a camera frame is supplied")
    func hiddenBubble() throws {
        let camera = try solid(0, 1, 0, size: CGSize(width: 160, height: 120))
        let composed = try composer(edit(camera: CameraBubble(isVisible: false)))
            .frame(at: 0, source: halvedSource(), camera: camera)
        let frame = try render(composed, size: sourceSize)
        #expect(frame.at(380, 190).blue > 200, "a hidden bubble was drawn anyway")
    }

    @Test("A rounded bubble leaves its corners alone")
    func roundedBubbleCorners() throws {
        let bubble = CameraBubble(
            placement: .bottomTrailing,
            sizeFraction: 0.5,
            marginFraction: 0,
            roundness: 1,
            isVisible: true
        )
        let camera = try solid(0, 1, 0, size: CGSize(width: 160, height: 160))
        let composed = try composer(edit(camera: bubble)).frame(at: 0, source: halvedSource(), camera: camera)
        let frame = try render(composed, size: sourceSize)

        let rect = bubble.frame(in: sourceSize)
        #expect(frame.at(Int(rect.midX), Int(rect.midY)).green > 180, "the middle of the bubble is missing")
        let corner = frame.at(Int(rect.maxX) - 2, Int(rect.maxY) - 2)
        #expect(corner.green < 180, "a fully-round bubble should not fill its own corner, found \(corner)")
    }

    // MARK: - Determinism

    /// What docs/09 U3.3 asks for by name: the preview and the export share the timeline, so
    /// composing the same instant twice has to produce the same bytes. If it does not, a
    /// five-minute render is the first place anybody finds out.
    @Test("Composing the same instant twice produces identical frames")
    func deterministic() throws {
        var telemetry = try cursorTelemetry(at: CGPoint(x: 250, y: 90))
        telemetry.clicks = [ClickEvent(time: 1.8, position: CGPoint(x: 250, y: 90))]
        telemetry.keystrokes = [KeystrokeEvent(time: 1.5, caption: "⌘⇧4")]
        let cue = ZoomCue(start: 0.5, duration: 3, magnification: 2, anchor: .fixed(CGPoint(x: 250, y: 90)))
        let edit = edit(zooms: [cue], showsCursor: true, showsClicks: true, showsKeystrokes: true)
        let camera = try solid(0, 1, 0, size: CGSize(width: 160, height: 120))

        for time in [0.0, 0.9, 1.9, 3.5] {
            let first = try render(
                composer(edit, telemetry: telemetry).frame(at: time, source: halvedSource(), camera: camera),
                size: sourceSize
            )
            let second = try render(
                composer(edit, telemetry: telemetry).frame(at: time, source: halvedSource(), camera: camera),
                size: sourceSize
            )
            #expect(first.checksum == second.checksum, "frames at \(time)s differ between composers")
        }
    }

    /// The other half of determinism: two *different* instants of a moving camera must not
    /// hash the same, or the test above would pass on a composer that ignored time.
    @Test("Different instants of a moving camera produce different frames")
    func timeMatters() throws {
        let cue = ZoomCue(start: 0, duration: 4, magnification: 3, anchor: .fixed(CGPoint(x: 60, y: 100)))
        let composed = composer(edit(zooms: [cue]))
        let early = try render(composed.frame(at: 0.05, source: halvedSource(), camera: nil), size: sourceSize)
        let late = try render(composed.frame(at: 3.5, source: halvedSource(), camera: nil), size: sourceSize)
        #expect(early.checksum != late.checksum)
    }
}
