import Foundation

/// Finding the event in force at an instant, without walking the recording (docs/10 R1.2).
///
/// Every telemetry stream is sorted by time — the recorder appends as things happen — and
/// every per-frame question is "what was true at `t`". `last(where:)` answers it by scanning
/// *backwards from the end*, so on a render, where time advances from zero, the match is
/// always near the front and every call walks almost the whole array. At 60 Hz telemetry
/// over ten minutes that is 36,000 samples scanned per lookup, per frame, and it grows
/// quadratically with the recording's length.
///
/// A binary search rather than the per-frame table the review suggested. The table is
/// marginally better asymptotically — O(N+F) against O(F log N) — and this is fifteen
/// comparisons instead of thirty-six thousand, needs no memory at all, and answers a random
/// scrub as cheaply as a sequential render. The memory matters: R2 is a program about
/// getting megabytes back out of the editor, and three per-frame tables for an hour-long
/// recording would put several of them straight back.
enum TimeSortedLookup {
    /// The index of the last element at or before `time`, or nil if every element is later.
    ///
    /// - Parameter time: the instant to ask about.
    /// - Parameter elements: sorted ascending by the value `key` returns. Sortedness is the
    ///   precondition and it is not checked — checking would cost more than the search.
    static func lastIndex<Element>(
        atOrBefore time: TimeInterval,
        in elements: [Element],
        key: (Element) -> TimeInterval
    ) -> Int? {
        var low = 0
        var high = elements.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if key(elements[mid]) <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// The elements in `window` seconds up to `time`, newest last.
    ///
    /// Walks back from the binary-searched position rather than filtering the whole array,
    /// which is what the caption lookup used to do — a fresh array allocated on every frame
    /// to hold the two or three chords that were showing.
    static func elements<Element>(
        within window: TimeInterval,
        endingAt time: TimeInterval,
        in elements: [Element],
        key: (Element) -> TimeInterval
    ) -> ArraySlice<Element> {
        guard let last = lastIndex(atOrBefore: time, in: elements, key: key) else { return [] }
        var first = last
        while first > 0, time - key(elements[first - 1]) <= window {
            first -= 1
        }
        // The newest may itself be older than the window, in which case nothing is showing.
        guard time - key(elements[last]) <= window else { return [] }
        return elements[first ... last]
    }
}
