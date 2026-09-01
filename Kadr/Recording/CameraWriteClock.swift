import CoreMedia
import Foundation

/// Where a camera sample lands in the file, after paused time has been taken out.
///
/// The screen writer already skips paused time: its clock is composited frames, not the
/// wall. The camera file has to do the same, or a two-second pause leaves the talking-head
/// two seconds ahead of the picture for the rest of the recording.
nonisolated enum CameraWriteClock: Sendable {
    /// Presentation time in the finished file for a sample captured at `sampleTime`.
    static func fileTime(
        sampleTime: CMTime,
        sessionStart: CMTime,
        pauseOffset: CMTime
    ) -> CMTime {
        CMTimeSubtract(CMTimeSubtract(sampleTime, sessionStart), pauseOffset)
    }
}
