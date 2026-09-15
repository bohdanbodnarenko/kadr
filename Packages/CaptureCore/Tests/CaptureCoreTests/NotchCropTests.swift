import CoreGraphics
import Foundation
import Shared
import Testing
@testable import CaptureCore

@Suite("Notch crop")
struct NotchCropTests {
    private let display = DisplayRect(x: 0, y: 0, width: 100, height: 50)

    @Test("A disabled setting leaves the capture alone")
    func disabled() {
        let capture = makeCapture(width: 200, height: 100, rect: display)
        let result = NotchCrop.apply(
            capture,
            enabled: false,
            topInsetPoints: 10,
            displayFrame: display
        )
        #expect(result.image.height == 100)
        #expect(result.metadata.pointRect == display)
    }

    @Test("A display without a notch is left alone")
    func noNotch() {
        let capture = makeCapture(width: 200, height: 100, rect: display)
        let result = NotchCrop.apply(
            capture,
            enabled: true,
            topInsetPoints: 0,
            displayFrame: display
        )
        #expect(result.image.height == 100)
    }

    @Test("A fullscreen still loses the empty notch strip")
    func cropsFullscreen() {
        let capture = makeCapture(width: 200, height: 100, rect: display)
        let result = NotchCrop.apply(
            capture,
            enabled: true,
            topInsetPoints: 10,
            displayFrame: display
        )
        #expect(result.image.width == 200)
        #expect(result.image.height == 78)
        #expect(result.metadata.pixelSize.height == 78)
        #expect(result.metadata.pointRect.minY == 11)
        #expect(result.metadata.pointRect.height == 39)
    }

    @Test("A black strip is cropped")
    func cropsEmptyBlackStrip() {
        let capture = makeCapture(width: 200, height: 100, rect: display) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 80, width: 200, height: 20))
        }
        #expect(NotchCrop.stripIsEmpty(capture.image, rows: 20))
        let result = NotchCrop.apply(
            capture,
            enabled: true,
            topInsetPoints: 10,
            displayFrame: display
        )
        #expect(result.image.height == 78)
    }

    @Test("Menu text in the strip is kept")
    func keepsMenuText() {
        let capture = makeCapture(width: 200, height: 100, rect: display) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 80, width: 200, height: 20))
        }
        #expect(!NotchCrop.stripIsEmpty(capture.image, rows: 20))
        let result = NotchCrop.apply(
            capture,
            enabled: true,
            topInsetPoints: 10,
            displayFrame: display
        )
        #expect(result.image.height == 100)
    }

    @Test("Near-black noise is still cropped")
    func cropsNearBlackNoise() {
        let capture = makeCapture(width: 200, height: 100, rect: display) { context in
            let level = CGFloat(NotchCrop.channelThreshold) / 255
            context.setFillColor(CGColor(srgbRed: level, green: level, blue: level, alpha: 1))
            context.fill(CGRect(x: 0, y: 80, width: 200, height: 20))
        }
        #expect(NotchCrop.stripIsEmpty(capture.image, rows: 20))
        let result = NotchCrop.apply(
            capture,
            enabled: true,
            topInsetPoints: 10,
            displayFrame: display
        )
        #expect(result.image.height == 78)
    }

    @Test("A strip taller than half the image is kept")
    func keepsStripTallerThanHalf() {
        let capture = makeCapture(width: 200, height: 100, rect: display)
        let result = NotchCrop.apply(
            capture,
            enabled: true,
            topInsetPoints: 30,
            displayFrame: display
        )
        #expect(result.image.height == 100)
    }

    @Test("A region that is not the full display is left alone")
    func ignoresPartialRegion() {
        let rect = DisplayRect(x: 10, y: 10, width: 40, height: 30)
        let capture = makeCapture(
            width: 80,
            height: 60,
            rect: rect,
            source: .region(display: 1)
        )
        let result = NotchCrop.apply(
            capture,
            enabled: true,
            topInsetPoints: 10,
            displayFrame: display
        )
        #expect(result.image.height == 60)
    }

    @Test("A short strip at the top of the display is not swallowed")
    func ignoresMenuBarOnly() {
        let rect = DisplayRect(x: 0, y: 0, width: 100, height: 12)
        let capture = makeCapture(width: 200, height: 24, rect: rect)
        let result = NotchCrop.apply(
            capture,
            enabled: true,
            topInsetPoints: 10,
            displayFrame: display
        )
        #expect(result.image.height == 24)
    }

    @Test("A padded window capture is not sliced as if it were the display")
    func ignoresCompositedBackdrop() {
        let capture = makeCapture(width: 240, height: 140, rect: display)
        let result = NotchCrop.apply(
            capture,
            enabled: true,
            topInsetPoints: 10,
            displayFrame: display
        )
        #expect(result.image.height == 140)
    }

    private func makeCapture(
        width: Int,
        height: Int,
        rect: DisplayRect,
        source: CaptureSource = .display(1),
        paint: ((CGContext) -> Void)? = nil
    ) -> Capture {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image: CGImage = {
            paint?(context)
            return context.makeImage()
        }() else {
            fatalError("Could not create a test capture")
        }
        return Capture(
            image: image,
            metadata: CaptureMetadata(
                source: source,
                displayID: 1,
                scale: .retina,
                pointRect: rect,
                pixelSize: PixelSize(width: width, height: height),
                colorSpaceName: nil,
                frontmostApp: nil
            )
        )
    }
}
