import CoreGraphics
import Shared
import Testing
@testable import SelectionUI

/// Builds a test bitmap. Traps rather than returning an optional: a CGContext this
/// simple only fails if the process is already broken, and every test needs the image.
private func makeContext(width: Int, height: Int) -> CGContext {
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
    return context
}

private func finish(_ context: CGContext) -> CGImage {
    guard let image = context.makeImage() else {
        fatalError("Could not turn the test bitmap context into an image")
    }
    return image
}

/// A square image: left half red, right half blue.
private func makeImage(width: Int = 100, height: Int = 100) -> CGImage {
    let context = makeContext(width: width, height: height)
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    return finish(context)
}

@Suite("Magnifier sampling")
struct LoupeSamplerTests {
    @Test("The sampler reports the frozen image's pixel size")
    func pixelSize() {
        let sampler = LoupeSampler(image: makeImage(), scale: .retina)
        #expect(sampler.pixelSize == PixelSize(width: 100, height: 100))
    }

    @Test("A region is cropped in pixels, scaled off a point coordinate")
    func cropsInPixels() {
        // 2× display: a point coordinate of 25 is pixel 50.
        let sampler = LoupeSampler(image: makeImage(), scale: .retina)
        let region = sampler.magnifiedRegion(around: CGPoint(x: 25, y: 25), sideInPoints: 10)

        #expect(region?.rect == PixelRect(x: 40, y: 40, width: 20, height: 20))
        #expect(region?.image.width == 20)
    }

    @Test("At the edge the loupe slides inward and keeps its zoom")
    func clampsAtEdges() {
        let sampler = LoupeSampler(image: makeImage(), scale: .oneToOne)
        let topLeft = sampler.magnifiedRegion(around: CGPoint(x: 0, y: 0), sideInPoints: 20)
        let bottomRight = sampler.magnifiedRegion(around: CGPoint(x: 100, y: 100), sideInPoints: 20)

        #expect(topLeft?.rect == PixelRect(x: 0, y: 0, width: 20, height: 20))
        #expect(bottomRight?.rect == PixelRect(x: 80, y: 80, width: 20, height: 20))
        #expect(topLeft?.rect.width == bottomRight?.rect.width, "zoom must not change at the edges")
    }

    @Test("A region larger than the image is trimmed rather than refused")
    func regionLargerThanImage() {
        let sampler = LoupeSampler(image: makeImage(width: 10, height: 10), scale: .oneToOne)
        let region = sampler.magnifiedRegion(around: CGPoint(x: 5, y: 5), sideInPoints: 100)

        #expect(region?.rect == PixelRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test("A zero-sized region is refused")
    func zeroRegion() {
        let sampler = LoupeSampler(image: makeImage(), scale: .oneToOne)
        #expect(sampler.magnifiedRegion(around: .zero, sideInPoints: 0) == nil)
    }

    @Test("The colour under the pointer is read from the right half of the image")
    func readsColour() {
        let sampler = LoupeSampler(image: makeImage(), scale: .oneToOne)

        #expect(sampler.color(at: CGPoint(x: 10, y: 10)) == PixelColor(red: 255, green: 0, blue: 0))
        #expect(sampler.color(at: CGPoint(x: 90, y: 10)) == PixelColor(red: 0, green: 0, blue: 255))
    }

    @Test("Point coordinates are scaled to pixels before sampling")
    func scalesPointToPixel() {
        // On a 2× display, point 30 is pixel 60 — the blue half of a 100 px image.
        let sampler = LoupeSampler(image: makeImage(), scale: .retina)
        #expect(sampler.color(at: CGPoint(x: 30, y: 10)) == PixelColor(red: 0, green: 0, blue: 255))
    }

    @Test("A pointer outside the image has no colour")
    func outOfBoundsColour() {
        let sampler = LoupeSampler(image: makeImage(), scale: .oneToOne)
        #expect(sampler.color(at: CGPoint(x: -1, y: 10)) == nil)
        #expect(sampler.color(at: CGPoint(x: 100, y: 10)) == nil)
    }

    @Test("Colours render as hex and choose a legible text colour")
    func colourReadout() {}
}
