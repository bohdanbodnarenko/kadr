import CoreMedia
import Foundation

/// A fixed output clock over a variable-frame-rate source (docs/16 STU-A2).
///
/// ScreenCaptureKit only writes a frame when pixels change. Stepping one output frame
/// per source sample therefore freezes zooms, pans and the cursor on a static screen.
/// This clock ticks at the export frame rate and holds the newest source sample whose
/// PTS is at or before the tick.
public enum VariableFrameClock: Sendable {
    public static func frameCount(duration: TimeInterval, frameRate: Int) -> Int {
        max(Int((max(duration, 0) * Double(max(frameRate, 1))).rounded()), 1)
    }

    public static func presentationTime(frame: Int, frameRate: Int) -> CMTime {
        let fps = max(frameRate, 1)
        return CMTime(value: CMTimeValue(max(frame, 0)), timescale: CMTimeScale(fps))
    }

    /// Walks source timestamps, keeping the latest at or before each output tick.
    ///
    /// Resets the held sample when `clipIDs` change so a stale frame never crosses a cut.
    static func heldIndices(
        sourceTimes: [TimeInterval],
        clipIDs: [Int]? = nil,
        duration: TimeInterval,
        frameRate: Int
    ) -> [Int?] {
        let count = frameCount(duration: duration, frameRate: frameRate)
        var held: Int?
        var next = 0
        var lastClip: Int?
        var result: [Int?] = []
        result.reserveCapacity(count)
        for frame in 0 ..< count {
            let tick = Double(frame) / Double(max(frameRate, 1))
            let clip = clipIDs.flatMap { ids in
                next < ids.count ? ids[min(next, ids.count - 1)] : ids.last
            }
            if let clip, clip != lastClip {
                held = nil
                lastClip = clip
            }
            while next < sourceTimes.count, sourceTimes[next] <= tick {
                held = next
                next += 1
                if let ids = clipIDs, next - 1 < ids.count {
                    lastClip = ids[next - 1]
                }
            }
            result.append(held)
        }
        return result
    }
}
