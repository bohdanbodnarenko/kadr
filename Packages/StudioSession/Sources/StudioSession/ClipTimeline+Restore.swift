import Foundation

public extension ClipTimeline {
    /// Puts back the parts of `[start, end)` of the recording that no clip plays, the
    /// inverse of `removingSourceRange` (docs/18 STU-10).
    ///
    /// The transcript showed a cut word struck through with no way back short of undo,
    /// which also unwinds everything done since. Each restored piece plays at real speed,
    /// goes where the source order puts it, and joins a neighbour it touches at the same
    /// speed, so cutting a word and restoring it gives back the timeline it started from.
    func restoringSourceRange(from start: TimeInterval, to end: TimeInterval) -> ClipTimeline {
        guard end > start else { return self }
        var result = clips
        for gap in uncovered(from: start, to: end) {
            let piece = Clip(sourceStart: gap.lowerBound, sourceDuration: gap.upperBound - gap.lowerBound)
            let index = result.firstIndex { $0.sourceStart >= piece.sourceEnd } ?? result.endIndex
            result.insert(piece, at: index)
        }
        return ClipTimeline(clips: Self.joiningTouching(result))
    }

    /// The parts of `[start, end)` no clip covers, in order.
    private func uncovered(from start: TimeInterval, to end: TimeInterval) -> [Range<TimeInterval>] {
        let covered = clips.map(\.sourceRange).sorted { $0.lowerBound < $1.lowerBound }
        var gaps: [Range<TimeInterval>] = []
        var cursor = start
        for range in covered where range.upperBound > cursor && range.lowerBound < end {
            if range.lowerBound > cursor {
                gaps.append(cursor ..< min(range.lowerBound, end))
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < end {
            gaps.append(cursor ..< end)
        }
        return gaps.filter { $0.upperBound - $0.lowerBound > 0.001 }
    }

    /// Joins neighbours that continue each other at the same speed, keeping the first id.
    private static func joiningTouching(_ clips: [Clip]) -> [Clip] {
        var joined: [Clip] = []
        for clip in clips {
            if let last = joined.last, last.speed == clip.speed, abs(last.sourceEnd - clip.sourceStart) < 0.001 {
                joined[joined.count - 1].sourceDuration = clip.sourceEnd - last.sourceStart
            } else {
                joined.append(clip)
            }
        }
        return joined
    }
}
