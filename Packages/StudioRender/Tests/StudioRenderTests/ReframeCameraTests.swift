import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

@Suite("Reframe follow-camera")
struct ReframeCameraTests {
    private let source = CGSize(width: 1920, height: 1080)
    private let window = CGSize(width: 608, height: 1080)

    @Test("A pointer at the left edge is inside the crop within a second")
    func followsPointer() {
        let samples = stride(from: 0.0, through: 2, by: 1.0 / 30).map { time in
            PointerSample(time: time, position: CGPoint(x: source.width * 0.1, y: source.height / 2))
        }
        let camera = ReframeCamera(
            sourceSize: source,
            windowSize: window,
            duration: 2,
            pointer: samples,
            zooms: []
        )
        let crop = camera.crop(at: 1)
        #expect(crop.minX < source.width * 0.1)
        #expect(crop.maxX > source.width * 0.1)
        #expect(crop.minX >= -0.5)
        #expect(crop.maxX <= source.width + 0.5)
    }

    @Test("The crop never leaves the source")
    func staysInside() {
        let samples = [
            PointerSample(time: 0, position: .zero),
            PointerSample(time: 1, position: CGPoint(x: 1920, y: 1080))
        ]
        let camera = ReframeCamera(
            sourceSize: source,
            windowSize: window,
            duration: 1.2,
            pointer: samples,
            zooms: []
        )
        for frame in 0 ... 60 {
            let crop = camera.crop(at: Double(frame) / 50)
            #expect(crop.minX >= -0.01)
            #expect(crop.minY >= -0.01)
            #expect(crop.maxX <= source.width + 0.01)
            #expect(crop.maxY <= source.height + 0.01)
        }
    }
}
