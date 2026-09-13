import CaptureCore
import CoreGraphics
import SelectionUI
import Shared
import Testing
@testable import Kadr

@Suite("Freeze inspect")
struct FreezeInspectTests {
    @Test("A held freeze becomes a display capture with those pixels")
    func freezeBecomesCapture() {
        let frozen = FrozenDisplay(
            geometry: DisplayGeometry(
                displayID: 42,
                frame: DisplayRect(x: 0, y: 0, width: 100, height: 80),
                scale: .oneToOne
            ),
            image: makeImage(width: 100, height: 80)
        )
        let frontmost = AppIdentity(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let capture = AreaCaptureCoordinator.capture(from: frozen, frontmost: frontmost)

        #expect(capture.image.width == 100)
        #expect(capture.image.height == 80)
        #expect(capture.metadata.displayID == 42)
        #expect(capture.metadata.pointRect.width == 100)
        #expect(capture.metadata.frontmostApp == frontmost)
        if case let .display(id) = capture.metadata.source {
            #expect(id == 42)
        } else {
            Issue.record("expected a display source")
        }
    }
}

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
        fatalError("Could not create a \(width)×\(height) test bitmap")
    }
    context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        fatalError("Could not turn the test bitmap into an image")
    }
    return image
}
