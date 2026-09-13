import CoreGraphics
import Foundation
import Testing
@testable import MediaExport

@Suite("Window backdrop compositor")
struct WindowBackdropCompositorTests {
    @Test("A solid fill grows the canvas by the padding on every side")
    func solidFillPads() {
        let window = makeImage(width: 20, height: 10, red: 1, green: 0, blue: 0)
        let result = WindowBackdropCompositor.composite(
            window,
            onto: .color(red: 0, green: 0, blue: 1),
            padding: 5
        )
        #expect(result?.width == 30)
        #expect(result?.height == 20)
    }

    @Test("Zero padding keeps the window's pixel size")
    func zeroPaddingKeepsSize() {
        let window = makeImage(width: 16, height: 16, red: 1, green: 1, blue: 1)
        let result = WindowBackdropCompositor.composite(
            window,
            onto: .color(red: 0, green: 0, blue: 0),
            padding: 0
        )
        #expect(result?.width == 16)
        #expect(result?.height == 16)
    }

    @Test("An image fill covers the padded canvas")
    func imageFillCovers() {
        let window = makeImage(width: 10, height: 10, red: 1, green: 0, blue: 0)
        let fill = makeImage(width: 4, height: 8, red: 0, green: 1, blue: 0)
        let result = WindowBackdropCompositor.composite(
            window,
            onto: .image(fill),
            padding: 10
        )
        #expect(result?.width == 30)
        #expect(result?.height == 30)
    }
}

private func makeImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap")
    }
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let filled = context.makeImage() else {
        fatalError("Could not fill a test bitmap")
    }
    return filled
}
