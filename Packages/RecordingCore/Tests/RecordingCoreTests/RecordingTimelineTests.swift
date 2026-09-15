import Foundation
import Testing
@testable import RecordingCore

@Suite("Recording timeline")
struct RecordingTimelineTests {
    @Test("Host time inside a segment maps onto recording time")
    func mapsInsideSegment() {
        var timeline = RecordingTimeline()
        timeline.beginSegment(hostStart: 10, recordingOffset: 0)
        timeline.advance(hostEnd: 15)
        #expect(timeline.recordingTime(forHost: 10) == 0)
        #expect(timeline.recordingTime(forHost: 12.5) == 2.5)
        #expect(timeline.recordingTime(forHost: 15) == 5)
    }

    @Test("Host time during a pause is nil")
    func pauseIsNil() {
        var timeline = RecordingTimeline()
        timeline.beginSegment(hostStart: 0, recordingOffset: 0)
        timeline.advance(hostEnd: 5)
        timeline.beginSegment(hostStart: 8, recordingOffset: 5)
        timeline.advance(hostEnd: 10)
        #expect(timeline.recordingTime(forHost: 6) == nil)
        #expect(timeline.recordingTime(forHost: 8) == 5)
        #expect(timeline.recordingTime(forHost: 9) == 6)
    }

    @Test("A second segment does not rewind")
    func secondSegmentContinues() {
        var timeline = RecordingTimeline()
        timeline.beginSegment(hostStart: 100, recordingOffset: 0)
        timeline.advance(hostEnd: 110)
        timeline.beginSegment(hostStart: 120, recordingOffset: 10)
        timeline.advance(hostEnd: 125)
        #expect(timeline.recordingTime(forHost: 122) == 12)
    }
}
