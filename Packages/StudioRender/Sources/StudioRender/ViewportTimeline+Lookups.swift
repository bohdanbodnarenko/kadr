import Foundation
import StudioSession

// The two lookups `ViewportTimeline` builds once and asks at every step (docs/09 U3.3).

/// `ClipTimeline.sourceTime(forEdited:)`, for a playhead that only moves forward.
///
/// The timeline answers by whittling the time down clip by clip from the first, which is
/// linear in the number of clips — and a filler-word pass leaves hundreds. At 72,000 steps
/// that walk was nearly all of the timeline's cost.
///
/// The obvious fix, subtracting a running total instead, gives a number that can differ
/// from the timeline's in the last bit. That matters only through what the number is used
/// for here, which is two yes-or-no questions: which clip, and which zoom cue. So the fast
/// answer comes with an error bound, and a question it cannot settle beyond doubt — a step
/// within a hair of a cut or a cue edge — is asked again the timeline's own way. Everywhere
/// else the answers are provably the same, and the camera is bit-for-bit the one it was.
struct EditedToSource {
    private let starts: [TimeInterval]
    private let speeds: [Double]
    private let durations: [TimeInterval]
    /// `prefix[i]` is the edited time at which clip `i` starts, summed left to right.
    private let prefix: [TimeInterval]
    /// Every magnitude in the clip list is at most this, or nil if some are not finite.
    private let magnitude: Double?
    private let isEmpty: Bool

    /// Where a forward-moving caller is up to.
    struct Cursor {
        fileprivate var clip = 0
    }

    /// A source time, and how far from the timeline's own answer it can be.
    struct Estimate {
        let source: TimeInterval
        let tolerance: Double
    }

    init(_ timeline: ClipTimeline) {
        starts = timeline.clips.map(\.sourceStart)
        speeds = timeline.clips.map(\.speed)
        durations = timeline.clips.map(\.editedDuration)
        var running: TimeInterval = 0
        var prefix = [running]
        for duration in durations {
            running += duration
            prefix.append(running)
        }
        self.prefix = prefix
        isEmpty = timeline.clips.isEmpty
        let largest = ([running] + durations + starts).map(abs).max() ?? 0
        magnitude = largest.isFinite && speeds.allSatisfy(\.isFinite) ? max(largest, 1) : nil
    }

    func makeCursor() -> Cursor {
        Cursor()
    }

    /// Exactly `ClipTimeline.sourceTime(forEdited:)`, same arithmetic in the same order;
    /// the edited time itself when there are no clips.
    func sourceTime(forEdited time: TimeInterval) -> TimeInterval? {
        if isEmpty {
            return time
        }
        guard time >= 0 else { return nil }
        var remaining = time
        for index in durations.indices {
            if remaining < durations[index] {
                return starts[index] + remaining * speeds[index]
            }
            remaining -= durations[index]
        }
        return nil
    }

    /// The source time for `time` (or `time` itself past the end), with a bound on how far
    /// it is from `sourceTime(forEdited:) ?? time`. Nil when even the clip is in doubt.
    ///
    /// `time` must not go backwards between calls with the same cursor.
    ///
    /// The bound: every value met is at most `M` in magnitude, so each rounded operation is
    /// off by at most half a unit in the last place of `M`. The timeline's remaining time
    /// after `k` clips has taken `k` such operations and the running total another `k`, so
    /// the two remainders differ by at most `(k + 1)` units. Scaling by the clip's speed and
    /// adding its start costs two more rounded operations on numbers at most `M × speed`.
    /// The factors below are far larger than that, which costs nothing: a wider margin only
    /// means a few more steps take the exact path.
    func estimate(forEdited time: TimeInterval, cursor: inout Cursor) -> Estimate? {
        if isEmpty {
            return Estimate(source: time, tolerance: 0)
        }
        guard time.isFinite, let clipMagnitude = magnitude else { return nil }
        guard time >= 0 else {
            return Estimate(source: time, tolerance: 0)
        }
        let count = durations.count
        // Only ever forward: `time - prefix[k]` grows with `time`, so a clip that is behind
        // the playhead stays behind it.
        while cursor.clip < count, !(time - prefix[cursor.clip] < durations[cursor.clip]) {
            cursor.clip += 1
        }
        let clip = cursor.clip
        // A handful of clips in, the exact walk is as cheap as the estimate.
        if clip < 4 {
            return Estimate(source: sourceTime(forEdited: time) ?? time, tolerance: 0)
        }
        // Every value either walk meets is at most this.
        let magnitude = max(clipMagnitude, time)
        let unit = magnitude.ulp
        let margin = 4 * Double(count + 2) * unit
        let remaining = time - prefix[clip]
        // The timeline passed every clip before this one only if its remainder never went
        // negative; the running remainder only shrinks, so the last one is the one to test.
        guard remaining > margin else { return nil }
        guard clip < count else {
            return Estimate(source: time, tolerance: 0)
        }
        guard durations[clip] - remaining > margin else { return nil }
        let speed = speeds[clip]
        let source = starts[clip] + remaining * speed
        let tolerance = (speed + 2) * margin + 8 * max(abs(source), magnitude * speed).ulp
        return Estimate(source: source, tolerance: tolerance)
    }
}

/// "The last cue whose range contains this moment", answered by binary search.
///
/// Every cue starts and ends at a boundary. Between two neighbouring boundaries the answer
/// cannot change — a range that contains one point strictly inside the gap contains all of
/// them — so it is worked out once per gap and once per boundary (a closed range contains
/// its ends, and a boundary is where two answers meet). A query is then a search of the
/// boundaries, rather than a scan of every cue.
struct CueLookup {
    private let boundaries: [TimeInterval]
    /// The answer exactly at each boundary.
    private let atBoundary: [Int?]
    /// The answer strictly between boundary `i` and `i + 1`.
    private let between: [Int?]

    init(_ cues: [ZoomCue]) {
        let ranges = cues.map(\.range)
        let boundaries = Array(Set(ranges.flatMap { [$0.lowerBound, $0.upperBound] })).sorted()
        self.boundaries = boundaries
        atBoundary = boundaries.map { point in
            ranges.lastIndex { $0.contains(point) }
        }
        between = zip(boundaries, boundaries.dropFirst()).map { lower, upper in
            ranges.lastIndex { $0.lowerBound <= lower && $0.upperBound >= upper }
        }
    }

    /// The index of the last cue containing `time`, in the order the cues were given.
    func last(containing time: TimeInterval) -> Int? {
        guard !time.isNaN, !boundaries.isEmpty else { return nil }
        let low = firstBoundary(atOrAfter: time)
        if low < boundaries.count, boundaries[low] == time {
            return atBoundary[low]
        }
        guard low > 0, low < boundaries.count else { return nil }
        return between[low - 1]
    }

    /// The same, for a time known only to within `tolerance` — or `.none` when a boundary
    /// is close enough that the true time might be on the other side of it.
    func last(containing time: TimeInterval, within tolerance: Double) -> Int?? {
        guard tolerance > 0 else { return .some(last(containing: time)) }
        guard !time.isNaN, !boundaries.isEmpty else { return .some(nil) }
        let low = firstBoundary(atOrAfter: time)
        if low < boundaries.count, boundaries[low] - time <= tolerance {
            return .none
        }
        if low > 0, time - boundaries[low - 1] <= tolerance {
            return .none
        }
        guard low > 0, low < boundaries.count else { return .some(nil) }
        return .some(between[low - 1])
    }

    private func firstBoundary(atOrAfter time: TimeInterval) -> Int {
        var low = 0
        var high = boundaries.count
        while low < high {
            let mid = (low + high) / 2
            if boundaries[mid] < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
