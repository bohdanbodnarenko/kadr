import CoreGraphics
import Testing
@testable import AnnotationRender

/// Finding the window inside a shadowed capture (docs/03 §3 P2).
@Suite("Capture visible bounds")
struct CaptureVisibleBoundsTests {
    /// A 200×160 px capture: transparent, a translucent "shadow", and an opaque "window"
    /// whose top-left corner is at (`windowX`, `windowY`) in top-left pixel coordinates.
    private func shadowedCapture(
        windowX: Int = 20,
        windowY: Int = 10,
        windowWidth: Int = 150,
        windowHeight: Int = 120,
        hasAlpha: Bool = true
    ) -> CGImage {
        let width = 200
        let height = 160
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: hasAlpha
                ? CGImageAlphaInfo.premultipliedLast.rawValue
                : CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            fatalError("Could not create a test bitmap")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // Context space is bottom-up; the window is specified top-down.
        let window = CGRect(
            x: windowX,
            y: height - windowY - windowHeight,
            width: windowWidth,
            height: windowHeight
        )
        context.setFillColor(CGColor(gray: 0, alpha: 0.45))
        context.fill(window.insetBy(dx: -8, dy: -8).intersection(CGRect(x: 0, y: 0, width: width, height: height)))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(window)
        guard let image = context.makeImage() else {
            fatalError("Could not create a test image")
        }
        return image
    }

    @Test("A shadowed window is found, in points, top-left origin")
    func findsTheWindow() {
        let bounds = CaptureVisibleBounds.find(in: shadowedCapture(), scale: 2)
        #expect(bounds == CGRect(x: 10, y: 5, width: 75, height: 60))
    }

    @Test("An image with no alpha channel is left whole")
    func opaqueFormatIsIgnored() {
        #expect(CaptureVisibleBounds.find(in: shadowedCapture(hasAlpha: false), scale: 2) == nil)
    }

    @Test("A capture opaque to its edges is not trimmed", arguments: [
        (0, 10, 150, 120),
        (20, 0, 150, 120),
        (50, 10, 150, 120),
        (0, 0, 200, 160)
    ])
    func edgeToEdgeIsNotAShadow(x: Int, y: Int, width: Int, height: Int) {
        let image = shadowedCapture(windowX: x, windowY: y, windowWidth: width, windowHeight: height)
        #expect(CaptureVisibleBounds.find(in: image, scale: 1) == nil)
    }

    @Test("A small opaque detail is not mistaken for the capture")
    func tinyOpaqueRegionIsIgnored() {
        let image = shadowedCapture(windowX: 90, windowY: 70, windowWidth: 20, windowHeight: 20)
        #expect(CaptureVisibleBounds.find(in: image, scale: 1) == nil)
    }

    @Test("Pixel bounds are the rows and columns holding opaque pixels")
    func pixelBounds() {
        let width = 6
        let height = 5
        var alpha = [UInt8](repeating: 0, count: width * height)
        alpha[1 * width + 2] = 255
        alpha[3 * width + 4] = 251
        alpha[4 * width + 5] = 200
        #expect(
            CaptureVisibleBounds.opaquePixelBounds(bytes: alpha, width: width, height: height)
                == CGRect(x: 2, y: 1, width: 3, height: 3)
        )
        #expect(
            CaptureVisibleBounds.opaquePixelBounds(
                bytes: [UInt8](repeating: 120, count: width * height),
                width: width,
                height: height
            ) == nil
        )
    }

    @Test("Alpha is read from its own byte in a multi-channel layout")
    func interleavedAlpha() {
        // Gray, alpha: bright but transparent pixels must not count as opaque.
        var bytes = [UInt8](repeating: 255, count: 4 * 3 * 2)
        for index in stride(from: 1, to: bytes.count, by: 2) {
            bytes[index] = 0
        }
        bytes[(1 * 4 + 1) * 2 + 1] = 255
        #expect(
            CaptureVisibleBounds.opaquePixelBounds(
                bytes: bytes,
                width: 4,
                height: 3,
                bytesPerPixel: 2,
                alphaOffset: 1
            ) == CGRect(x: 1, y: 1, width: 1, height: 1)
        )
    }
}
