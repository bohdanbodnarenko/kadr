import CoreMedia
import Foundation
import Testing
@testable import StudioRender

@Suite("Variable-frame export clock")
struct VariableFrameClockTests {
    @Test("A 2 s gap still emits fps × duration frames")
    func gapStillTicks() {
        let times: [TimeInterval] = [0, 0.04, 2.0]
        let held = VariableFrameClock.heldIndices(sourceTimes: times, duration: 3, frameRate: 30)
        #expect(held.count == 90)
        #expect(held[0] == 0)
        #expect(held[30] == 1, "a static second still holds the last source frame")
        #expect(held[60] == 2)
        #expect(held[89] == 2)
    }

    @Test("A clip change drops the held frame")
    func clipChangeResets() {
        let times: [TimeInterval] = [0, 0.5, 1.0, 1.5]
        let clips = [0, 0, 1, 1]
        let held = VariableFrameClock.heldIndices(
            sourceTimes: times,
            clipIDs: clips,
            duration: 2,
            frameRate: 10
        )
        #expect(held.count == 20)
    }

    @Test("Presentation timestamps use the export timescale")
    func presentationTimescale() {
        let time = VariableFrameClock.presentationTime(frame: 15, frameRate: 30)
        #expect(time.timescale == 30)
        #expect(CMTimeGetSeconds(time) == 0.5)
    }
}
