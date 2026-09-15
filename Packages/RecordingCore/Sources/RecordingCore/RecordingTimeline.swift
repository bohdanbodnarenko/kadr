import Foundation

/// Maps host-clock instants onto recording time, skipping pauses (docs/16 REC-9).
///
/// ScreenCaptureKit only emits a complete frame when pixels change. The reconstructed
/// cursor stamps events with the last complete frame, so a static screen freezes that
/// clock. Anchors from sample host timestamps keep the mapping honest even when no
/// picture arrives.
public struct RecordingTimeline: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var hostStart: TimeInterval
        public var hostEnd: TimeInterval
        public var recordingOffset: TimeInterval

        public init(hostStart: TimeInterval, hostEnd: TimeInterval, recordingOffset: TimeInterval) {
            self.hostStart = hostStart
            self.hostEnd = max(hostEnd, hostStart)
            self.recordingOffset = recordingOffset
        }
    }

    public var segments: [Segment]

    public init(segments: [Segment] = []) {
        self.segments = segments
    }

    /// Recording time for a host instant, or nil inside a pause (between segments).
    public func recordingTime(forHost host: TimeInterval) -> TimeInterval? {
        for segment in segments where host >= segment.hostStart && host <= segment.hostEnd {
            return segment.recordingOffset + (host - segment.hostStart)
        }
        return nil
    }

    /// Opens a new running segment at `hostStart`.
    public mutating func beginSegment(hostStart: TimeInterval, recordingOffset: TimeInterval) {
        segments.append(Segment(hostStart: hostStart, hostEnd: hostStart, recordingOffset: recordingOffset))
    }

    /// Extends the current segment's host end, or no-ops when there is none.
    public mutating func advance(hostEnd: TimeInterval) {
        guard !segments.isEmpty else { return }
        let index = segments.count - 1
        segments[index].hostEnd = max(segments[index].hostEnd, hostEnd)
    }
}
