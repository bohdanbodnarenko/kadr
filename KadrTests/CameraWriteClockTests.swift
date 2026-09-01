import CoreMedia
import Foundation
import Testing
@testable import Kadr

@Suite("Camera write clock")
struct CameraWriteClockTests {
    @Test("The first sample lands at zero")
    func firstSampleIsZero() {
        let start = CMTime(seconds: 10, preferredTimescale: 600)
        let sample = CMTime(seconds: 10, preferredTimescale: 600)
        let time = CameraWriteClock.fileTime(sampleTime: sample, sessionStart: start, pauseOffset: .zero)
        #expect(CMTimeGetSeconds(time) == 0)
    }

    @Test("Paused time is subtracted from the file clock")
    func pauseIsRemoved() {
        let start = CMTime(seconds: 5, preferredTimescale: 600)
        let sample = CMTime(seconds: 12, preferredTimescale: 600)
        let pause = CMTime(seconds: 2, preferredTimescale: 600)
        let time = CameraWriteClock.fileTime(sampleTime: sample, sessionStart: start, pauseOffset: pause)
        #expect(abs(CMTimeGetSeconds(time) - 5) < 0.0001)
    }
}
