import CoreGraphics
import Shared
import Testing
@testable import SelectionUI

private func makeImage(width: Int, height: Int) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a \(width)x\(height) test bitmap context")
    }
    context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        fatalError("Could not turn the test bitmap context into an image")
    }
    return image
}

private func frozen(scale: DisplayScale, pointWidth: CGFloat = 1000, pointHeight: CGFloat = 800) -> FrozenDisplay {
    let geometry = DisplayGeometry(
        displayID: 1,
        frame: DisplayRect(x: 0, y: 0, width: pointWidth, height: pointHeight),
        scale: scale
    )
    return FrozenDisplay(
        geometry: geometry,
        image: makeImage(width: geometry.pixelSize.width, height: geometry.pixelSize.height)
    )
}

@Suite("Cropping out of the frozen image")
struct FrozenDisplayTests {
    @Test("A crop on a 1× display is the point rect")
    func nonRetinaCrop() {
        let display = frozen(scale: .oneToOne)
        let cropped = display.croppedImage(localRect: CGRect(x: 100, y: 50, width: 200, height: 150))

        #expect(cropped?.width == 200)
        #expect(cropped?.height == 150)
    }

    @Test("A crop on Retina comes out at native pixels, not half size")
    func retinaCrop() {
        let display = frozen(scale: .retina)
        let cropped = display.croppedImage(localRect: CGRect(x: 100, y: 50, width: 200, height: 150))

        #expect(cropped?.width == 400, "a Retina crop must be at backing resolution")
        #expect(cropped?.height == 300)
    }

    @Test("The crop matches what the badge promised the user")
    func matchesBadge() {
        let display = frozen(scale: .retina)
        let rect = CGRect(x: 10.5, y: 20.5, width: 300.5, height: 200.5)
        let cropped = display.croppedImage(localRect: rect)
        let promised = DimensionFormatter.pixelSize(of: rect, scale: .retina)

        #expect(cropped?.width == promised.width)
        #expect(cropped?.height == promised.height)
    }

    @Test("A crop running past the edge is trimmed to the image")
    func cropBeyondEdge() {
        let display = frozen(scale: .oneToOne, pointWidth: 100, pointHeight: 100)
        let cropped = display.croppedImage(localRect: CGRect(x: 50, y: 50, width: 200, height: 200))

        #expect(cropped?.width == 50)
        #expect(cropped?.height == 50)
    }

    @Test("An empty selection crops nothing")
    func emptyCrop() {
        let display = frozen(scale: .retina)
        #expect(display.croppedImage(localRect: .zero) == nil)
        #expect(display.croppedImage(localRect: CGRect(x: 10, y: 10, width: 0, height: 50)) == nil)
    }
}
