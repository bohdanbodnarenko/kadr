import Foundation

public extension ClipTimeline {
    /// Only the part of the finished video between two edited times, for exporting the
    /// stretch between the in and out marks (docs/18 T-STU-11).
    ///
    /// Clips the range starts or ends inside are trimmed, keeping their speed and id; clips
    /// outside it are dropped. Cues stored in source time — zooms, captions — need nothing
    /// else, because the source moments they name are unchanged.
    func keepingEdited(_ range: ClosedRange<TimeInterval>) -> ClipTimeline {
        var elapsed: TimeInterval = 0
        var kept: [Clip] = []
        for clip in clips {
            let clipStart = elapsed
            let clipEnd = elapsed + clip.editedDuration
            elapsed = clipEnd
            let start = max(range.lowerBound, clipStart)
            let end = min(range.upperBound, clipEnd)
            guard end - start > 1e-6 else { continue }
            var trimmed = clip
            trimmed.sourceStart = clip.sourceStart + (start - clipStart) * clip.speed
            trimmed.sourceDuration = (end - start) * clip.speed
            kept.append(trimmed)
        }
        return ClipTimeline(clips: kept)
    }
}
