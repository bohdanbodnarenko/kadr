import CoreGraphics
import CoreImage
import Foundation
import StudioRender
import StudioSession
import Testing

/// Scrubbing a long recording must not rebuild the render plan (docs/10 R1.1, R2.7).
@Suite("Studio scrub latency")
struct StudioScrubLatencyTests {
    @Test("A playhead change on a 10-minute session composes in under 50 ms")
    func scrubIsUnderFiftyMilliseconds() {
        let size = CGSize(width: 320, height: 180)
        let duration: TimeInterval = 600
        let edit = StudioEdit.untouched(duration: duration)
        let plan = StudioRenderPlan(edit: edit, sourceSize: size)
        let composer = StudioFrameComposer(plan: plan, edit: edit, telemetry: InputTelemetry())
        let source = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: size))

        // Warm CoreImage so first-use compile is not the thing we measure.
        _ = composer.frame(at: 0, source: source, camera: nil)

        let frames = 20
        let start = ContinuousClock.now
        for step in 0 ..< frames {
            _ = composer.frame(at: duration * Double(step) / Double(frames), source: source, camera: nil)
        }
        let elapsed = ContinuousClock.now - start
        let milliseconds = (Double(elapsed.components.seconds) * 1e3)
            + (Double(elapsed.components.attoseconds) / 1e15)
        let perFrame = milliseconds / Double(frames)
        #expect(perFrame < 50, "playhead → composed frame took \(perFrame) ms")
    }
}
