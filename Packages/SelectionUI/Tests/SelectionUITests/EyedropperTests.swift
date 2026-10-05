import CoreGraphics
import Shared
import Testing
@testable import SelectionUI

/// A flat image of one known colour, so a sampled pixel has an expected answer.
private func makeSolidImage(red: Double, green: Double, blue: Double) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: 20,
        height: 20,
        bitsPerComponent: 8,
        bytesPerRow: 20 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap context")
    }
    context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    guard let image = context.makeImage() else {
        fatalError("Could not turn the test bitmap context into an image")
    }
    return image
}

/// Reading a colour out of the frozen capture (docs/03 §3 P3, docs/06 M22).
///
/// The point being pinned down is that the eyedropper reports the pixel in the *file*.
/// A picker that samples the live screen would answer a slightly different question, and
/// on a screen that has moved on since the freeze it would answer the wrong one.
@Suite("Eyedropper")
struct EyedropperTests {
    @Test("A sampled pixel becomes the color the maths works on")
    func samplerProducesAColour() throws {
        let sampler = LoupeSampler(image: makeSolidImage(red: 1, green: 0, blue: 0), scale: .retina)
        let pixel = try #require(sampler.color(at: CGPoint(x: 5, y: 5)))
        #expect(pixel.rgb.red8 == 255)
        #expect(pixel.rgb.green8 == 0)
        #expect(pixel.rgb.blue8 == 0)
        #expect(pixel.rgb.formatted(.hex) == "#FF0000")
        #expect(pixel.hexText == pixel.rgb.formatted(.hex))
    }

    @Test("Every notation is available for the same sample")
    func formatsAgree() throws {
        let sampler = LoupeSampler(image: makeSolidImage(red: 1, green: 1, blue: 1), scale: .retina)
        let colour = try #require(sampler.color(at: CGPoint(x: 1, y: 1))).rgb
        #expect(colour.formatted(.hex) == "#FFFFFF")
        #expect(colour.formatted(.rgb) == "rgb(255 255 255)")
        #expect(colour.formatted(.hsl) == "hsl(0 0% 100%)")
        #expect(colour.formatted(.oklch).hasPrefix("oklch("))
    }

    @Test("Two samples give a contrast readout")
    func twoSamplesContrast() throws {
        let dark = LoupeSampler(image: makeSolidImage(red: 0, green: 0, blue: 0), scale: .retina)
        let light = LoupeSampler(image: makeSolidImage(red: 1, green: 1, blue: 1), scale: .retina)

        let text = try #require(dark.color(at: CGPoint(x: 1, y: 1))).rgb
        let background = try #require(light.color(at: CGPoint(x: 1, y: 1))).rgb
        let pick = ColorPick(color: text, comparison: background, format: .hex)

        #expect(pick.wcagContrast.map { abs($0 - 21) < 0.01 } == true)
        #expect((pick.apcaLc ?? 0) > 100)
        #expect(pick.clipboardText.hasPrefix("#000000"))
    }

    @Test("A pixel outside the image reports nothing rather than guessing")
    func outsideTheImage() {
        let sampler = LoupeSampler(image: makeSolidImage(red: 0.5, green: 0.5, blue: 0.5), scale: .retina)
        #expect(sampler.color(at: CGPoint(x: 500, y: 500)) == nil)
    }
}
