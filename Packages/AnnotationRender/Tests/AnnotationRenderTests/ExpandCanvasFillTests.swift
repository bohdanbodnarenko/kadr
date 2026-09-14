import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

@Suite("Expand-canvas fill colour")
struct ExpandCanvasFillTests {
    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    private func solidImage(red: UInt8, green: UInt8, blue: UInt8, width: Int = 80, height: Int = 60) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not create a test bitmap context")
        }
        context.setFillColor(CGColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            fatalError("Could not create a test bitmap")
        }
        return image
    }

    private func components(of color: CGColor) -> RGB {
        let converted = color.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ) ?? color
        let parts = converted.components ?? [1, 1, 1, 1]
        return RGB(red: parts[0], green: parts[1], blue: parts[2])
    }

    @Test("A dark capture yields a dark edge fill")
    func darkCapture() {
        let image = solidImage(red: 32, green: 40, blue: 48)
        let fill = components(of: ExpandCanvasFill.color(around: image))
        #expect(fill.red < 0.35)
        #expect(fill.green < 0.35)
        #expect(fill.blue < 0.35)
        #expect(fill.red < fill.green)
        #expect(fill.green < fill.blue)
    }

    @Test("A light capture yields a light edge fill")
    func lightCapture() {
        let image = solidImage(red: 240, green: 242, blue: 245)
        let fill = components(of: ExpandCanvasFill.color(around: image))
        #expect(fill.red > 0.9)
        #expect(fill.green > 0.9)
        #expect(fill.blue > 0.9)
    }
}
