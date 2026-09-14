import AnnotationModel
import CoreGraphics
import Foundation
import Testing
@testable import AnnotationRender

@Suite("Counter badge drawing")
struct CounterRenderingTests {
    @Test("The digits sit inside the disc, not clipped to a shorter text box")
    func digitsAreNotCropped() {
        let spec = CounterSpec(
            number: 8,
            center: CGPoint(x: 40, y: 40),
            radius: 40,
            fill: .annotationRed,
            textColor: .white
        )
        let image = render(spec)
        // A CATextLayer whose height was only the radius clipped the lower bowl of 8.
        // Optical centering keeps white pixels in the lower half of the disc.
        #expect(hasWhite(in: image, region: CGRect(x: 30, y: 12, width: 20, height: 16)))
        #expect(hasWhite(in: image, region: CGRect(x: 30, y: 52, width: 20, height: 16)))
    }

    private func render(_ spec: CounterSpec) -> CGImage {
        let size = Int((spec.radius * 2).rounded())
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not create a badge bitmap")
        }
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        var local = spec
        local.center = CGPoint(x: spec.radius, y: spec.radius)
        CounterRendering.draw(local, in: context)
        guard let image = context.makeImage() else {
            fatalError("Could not read the badge bitmap")
        }
        return image
    }

    private func hasWhite(in image: CGImage, region: CGRect) -> Bool {
        let width = Int(region.width)
        let height = Int(region.height)
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        bytes.initialize(repeating: 0, count: width * height * 4)
        defer { bytes.deallocate() }
        guard let context = CGContext(
            data: bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(
            image,
            in: CGRect(
                x: -region.minX,
                y: -CGFloat(image.height) + region.maxY,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            if bytes[index] > 200, bytes[index + 1] > 200, bytes[index + 2] > 200 {
                return true
            }
        }
        return false
    }
}
