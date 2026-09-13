import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import RecordingCore

/// Overlays are drawn into the frames, not onto the screen (docs/03 §1.8, docs/04 §4.3).
///
/// These tests composite into a real `CVPixelBuffer` and read the pixels back, because the
/// two things that can go wrong here — drawing in the wrong place, and drawing upside down
/// — are both invisible to a type checker.
@Suite("Overlay compositing")
struct FrameCompositorTests {
    private static let width = 320
    private static let height = 200

    /// A BGRA buffer filled with mid grey, so both lighter and darker marks show up.
    private func makeBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.width,
            Self.height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            fatalError("Could not allocate a test pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * Self.height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// One BGRA pixel, read back out of the buffer.
    private struct Pixel: Equatable {
        var blue: UInt8
        var green: UInt8
        var red: UInt8

        /// The mid grey every test buffer starts as.
        static let untouched = Pixel(blue: 0x80, green: 0x80, red: 0x80)
    }

    /// Reads one pixel, in the frame's own top-left-origin coordinates.
    private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Pixel(blue: 0, green: 0, red: 0)
        }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
        return Pixel(blue: pointer[0], green: pointer[1], red: pointer[2])
    }

    private func bytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        return Data(bytes: base, count: CVPixelBufferGetBytesPerRow(buffer) * Self.height)
    }

    @Test("An empty overlay leaves the frame byte for byte alone")
    func emptyOverlayCostsNothing() {
        let buffer = makeBuffer()
        let before = bytes(buffer)
        FrameCompositor().draw(RecordingOverlay(), into: buffer)
        #expect(bytes(buffer) == before)
    }

    @Test("A click is drawn where the click happened, and nowhere else")
    func clickLandsAtItsPosition() {
        let buffer = makeBuffer()
        let overlay = RecordingOverlay(clicks: [
            ClickPulse(position: CGPoint(x: 100, y: 60), progress: 0)
        ])
        FrameCompositor().draw(overlay, into: buffer)

        // The dot at the centre is red on grey.
        let centre = pixel(buffer, x: 100, y: 60)
        #expect(centre.red > centre.blue)
        #expect(centre.red > 0x80)

        // The far corner is untouched. If the vertical flip were wrong, the mark would
        // land at y = 140 instead, which this catches.
        #expect(pixel(buffer, x: 100, y: 140) == .untouched)
        #expect(pixel(buffer, x: 300, y: 190) == .untouched)
    }

    @Test("A finished click has faded away")
    func finishedClickDrawsNothingSolid() {
        let buffer = makeBuffer()
        let overlay = RecordingOverlay(clicks: [
            ClickPulse(position: CGPoint(x: 100, y: 60), progress: 1)
        ])
        FrameCompositor().draw(overlay, into: buffer)
        #expect(pixel(buffer, x: 100, y: 60) == .untouched)
    }

    @Test("Keystrokes go where the setting says", arguments: [
        (KeystrokePosition.bottomCentre, 176, 24),
        (KeystrokePosition.bottomLeading, 176, 24),
        (KeystrokePosition.topCentre, 24, 176)
    ])
    func keystrokePillPosition(position: KeystrokePosition, drawn: Int, clear: Int) {
        let buffer = makeBuffer()
        let overlay = RecordingOverlay(keystrokes: "⌘⇧4", keystrokePosition: position)
        FrameCompositor().draw(overlay, into: buffer)

        let x = position == .bottomLeading ? 30 : 160
        #expect(pixel(buffer, x: x, y: drawn) != .untouched)
        // The other end of the frame is untouched, which is what pins the position down.
        #expect(pixel(buffer, x: x, y: clear) == .untouched)
    }

    @Test("The webcam picture is not drawn upside down")
    func webcamIsUpright() {
        let buffer = makeBuffer()
        FrameCompositor().draw(
            RecordingOverlay(webcamFrame: halfWhiteHalfBlack(), webcamIsCircular: false),
            into: buffer
        )

        // The PiP sits in the bottom-right corner, 22% of the short side.
        let side = Int(Double(Self.height) * 0.22)
        let margin = Int(Double(Self.height) * 0.04)
        let right = Self.width - margin - side / 2
        let bottom = Self.height - margin - side
        let top = pixel(buffer, x: right, y: bottom + side / 4)
        let low = pixel(buffer, x: right, y: bottom + side * 3 / 4)

        // White on top in the source means white on top in the frame.
        #expect(top.red > 0xC0)
        #expect(low.red < 0x40)
    }

    @Test("A filled click paints the centre, not a hollow ring")
    func filledClickCoversTheCentre() {
        let buffer = makeBuffer()
        let overlay = RecordingOverlay(
            clicks: [ClickPulse(position: CGPoint(x: 100, y: 60), progress: 0.4)],
            clickFilled: true
        )
        FrameCompositor().draw(overlay, into: buffer)
        let centre = pixel(buffer, x: 100, y: 60)
        #expect(centre.red > 0x80)
    }

    @Test("A fullscreen webcam covers the middle of the frame")
    func fullscreenWebcamCoversTheCentre() {
        let buffer = makeBuffer()
        FrameCompositor().draw(
            RecordingOverlay(
                webcamFrame: halfWhiteHalfBlack(),
                webcamIsCircular: false,
                webcamFillsFrame: true
            ),
            into: buffer
        )
        let top = pixel(buffer, x: Self.width / 2, y: Self.height / 4)
        let low = pixel(buffer, x: Self.width / 2, y: Self.height * 3 / 4)
        #expect(top.red > 0xC0)
        #expect(low.red < 0x40)
    }

    /// A source image whose top half is white and bottom half black.
    private func halfWhiteHalfBlack() -> CGImage {
        let size = 64
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            fatalError("Could not create a test image")
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // CGContext is bottom-left origin, so the white half drawn at the top of the
        // context is the top of the image.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: size / 2, width: size, height: size / 2))
        guard let image = context.makeImage() else { fatalError("Could not create a test image") }
        return image
    }
}
