import Accelerate
import Foundation

// Finding how far a page scrolled between two frames (docs/03 §1.6, docs/04 §4.4).
//
// Scrolling capture lives or dies on this one number. Everything here works on *row
// profiles* rather than pixels: each row of a frame is reduced to a handful of column
// averages, so aligning two frames is a one-dimensional search over a few thousand
// floats instead of a two-dimensional search over millions of pixels. That is what makes
// a live preview affordable while the user is still scrolling.
//
// It lives in `Shared` because both sides need it: the agent uses it on downsampled
// thumbnails to draw the growing strip, and the helper uses it on full frames to do the
// real stitch. The pixel-level fallback for when this is not sure enough belongs with the
// helper, which has the pixels.

/// A frame reduced to one small feature vector per row.
public struct RowProfile: Sendable, Hashable {
    /// Column buckets per row. More buckets discriminate better between rows that differ
    /// only in one place — a line of code, a Finder filename — at linear cost.
    public static let bucketCount = 24

    public let height: Int
    /// `height * bucketCount` values, row-major, each the mean luminance of one bucket.
    public let values: [Float]

    public init(height: Int, values: [Float]) {
        precondition(values.count == height * Self.bucketCount, "a row profile is bucketCount wide")
        self.height = height
        self.values = values
    }

    /// Builds a profile from 8-bit grayscale pixels.
    ///
    /// - Parameters:
    ///   - pixels: `height` rows of `bytesPerRow` bytes, one byte per pixel.
    public init(grayscale pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
        var values = [Float](repeating: 0, count: height * Self.bucketCount)
        guard width > 0, height > 0 else {
            self.init(height: 0, values: [])
            return
        }

        var row = [Float](repeating: 0, count: width)
        for y in 0 ..< height {
            let start = pixels.advanced(by: y * bytesPerRow)
            vDSP.convertElements(of: UnsafeBufferPointer(start: start, count: width), to: &row)
            for bucket in 0 ..< Self.bucketCount {
                let from = bucket * width / Self.bucketCount
                let to = max(from + 1, (bucket + 1) * width / Self.bucketCount)
                values[y * Self.bucketCount + bucket] = vDSP.mean(row[from ..< min(to, width)])
            }
        }
        self.init(height: height, values: values)
    }

    /// The mean absolute difference between two rows, one of this profile and one of
    /// another. 0 means identical.
    func distance(row: Int, to other: RowProfile, row otherRow: Int) -> Float {
        var total: Float = 0
        let base = row * Self.bucketCount
        let otherBase = otherRow * Self.bucketCount
        for bucket in 0 ..< Self.bucketCount {
            total += abs(values[base + bucket] - other.values[otherBase + bucket])
        }
        return total / Float(Self.bucketCount)
    }
}

/// How far the content moved between two frames, and how sure we are.
public struct ScrollAlignment: Sendable, Hashable {
    /// Rows the content moved up. Positive means the page scrolled down; 0 means the
    /// frame did not change, which is how settling is detected.
    public let offset: Int
    /// 0 to 1. Below `ScrollAligner.confidenceThreshold` the seam is worth flagging to
    /// the user rather than silently trusting (docs/03 §1.6).
    public let confidence: Double
    /// How much of the two frames actually overlapped at that offset.
    public let overlappingRows: Int

    public init(offset: Int, confidence: Double, overlappingRows: Int) {
        self.offset = offset
        self.confidence = confidence
        self.overlappingRows = overlappingRows
    }

    /// Nothing moved: the two frames are the same picture.
    public static let settled = ScrollAlignment(offset: 0, confidence: 1, overlappingRows: 0)
}

/// Chrome that does not scroll with the content.
///
/// Safari's toolbar, VS Code's tab bar and Slack's message composer all stay put while
/// the page moves underneath them. Including those rows in the search makes every offset
/// look partly right; repeating them down the strip makes the output nonsense. So they
/// are found once and then left out of both.
public struct StickyBands: Sendable, Hashable {
    public let header: Int
    public let footer: Int

    public init(header: Int, footer: Int) {
        self.header = header
        self.footer = footer
    }

    public static let none = StickyBands(header: 0, footer: 0)
}

public enum ScrollAligner {
    /// Below this, a seam is reported to the user instead of being trusted (docs/03 §1.6).
    public static let confidenceThreshold = 0.55

    /// Rows that must overlap before an offset is believable. A page that scrolled almost
    /// a whole frame leaves too little in common to match honestly.
    public static let minimumOverlap = 48

    /// Two rows this close together are the same row.
    ///
    /// Not zero: capture is not bit-exact across frames — subpixel antialiasing, a caret
    /// blinking, a hover state all move a few levels — and demanding equality would find
    /// no sticky header at all.
    static let sameRowTolerance: Float = 1.5

    /// Finds the chrome that stays put between two frames of the same scroll.
    ///
    /// Takes the offset the alignment already found, because "identical in both frames" is
    /// not enough on its own: a blank row next to the chrome is identical too, and so is
    /// the row the scroll happens to have replaced with an equally blank one. Those rows
    /// are ambiguous, and the tie goes to the content — chrome that eats a row of the page
    /// loses pixels the user captured, while a row of page treated as page costs nothing.
    public static func stickyBands(
        previous: RowProfile,
        current: RowProfile,
        offset: Int
    ) -> StickyBands {
        guard previous.height == current.height, previous.height > 0, offset > 0 else {
            return .none
        }
        let limit = previous.height / 3

        var header = 0
        while header < limit {
            let stays = previous.distance(row: header, to: current, row: header)
            guard stays < sameRowTolerance else { break }
            // Does the body reading fit this row just as well? Then it is not chrome.
            let body = header + offset
            let ambiguous = body < previous.height
                && previous.distance(row: body, to: current, row: header) < sameRowTolerance
            guard !ambiguous else { break }
            header += 1
        }

        var footer = 0
        while footer < limit {
            let row = previous.height - 1 - footer
            let stays = previous.distance(row: row, to: current, row: row)
            guard stays < sameRowTolerance else { break }
            // Near the bottom the correspondence runs the other way: content that was at
            // `row` in the previous frame is at `row - offset` in this one.
            let body = row - offset
            let ambiguous = body >= 0
                && previous.distance(row: row, to: current, row: body) < sameRowTolerance
            guard !ambiguous else { break }
            footer += 1
        }

        // A frame that did not move at all reads as entirely sticky. That is not chrome,
        // it is a still page, and the caller finds out from the alignment instead.
        if header + footer >= previous.height {
            return .none
        }
        return StickyBands(header: header, footer: footer)
    }

    /// Finds how far the content moved between `previous` and `current`.
    ///
    /// Both frames must be the same height. The search runs over the body region only,
    /// scoring every candidate offset by mean absolute difference and taking the best.
    /// Confidence compares that score against the best *unrelated* candidate, so a page of
    /// identical rows — Terminal scrollback, a Finder list — reports low confidence
    /// instead of a confident guess.
    public static func align(
        previous: RowProfile,
        current: RowProfile,
        sticky: StickyBands = .none,
        minimumOverlap: Int = ScrollAligner.minimumOverlap
    ) -> ScrollAlignment {
        guard previous.height == current.height, previous.height > 0 else {
            return ScrollAlignment(offset: 0, confidence: 0, overlappingRows: 0)
        }

        let top = sticky.header
        let bottom = previous.height - sticky.footer
        let bodyHeight = bottom - top
        guard bodyHeight > minimumOverlap else {
            return ScrollAlignment(offset: 0, confidence: 0, overlappingRows: 0)
        }

        let maximumOffset = bodyHeight - minimumOverlap
        let buckets = RowProfile.bucketCount
        var scores = [Float](repeating: .greatestFiniteMagnitude, count: maximumOffset + 1)
        var difference = [Float](repeating: 0, count: bodyHeight * buckets)

        // The overlap at any offset is a contiguous run of both arrays, so each candidate
        // is one vectorised subtract and one magnitude sum rather than a loop over rows.
        // At a few hundred candidate offsets per frame that difference is what keeps the
        // live preview live.
        previous.values.withUnsafeBufferPointer { previousValues in
            current.values.withUnsafeBufferPointer { currentValues in
                difference.withUnsafeMutableBufferPointer { scratch in
                    guard let previousBase = previousValues.baseAddress,
                          let currentBase = currentValues.baseAddress,
                          let scratchBase = scratch.baseAddress
                    else { return }

                    for offset in 0 ... maximumOffset {
                        let count = vDSP_Length((bodyHeight - offset) * buckets)
                        vDSP_vsub(
                            currentBase + top * buckets,
                            1,
                            previousBase + (top + offset) * buckets,
                            1,
                            scratchBase,
                            1,
                            count
                        )
                        var total: Float = 0
                        vDSP_svemg(scratchBase, 1, &total, count)
                        scores[offset] = total / Float(count)
                    }
                }
            }
        }

        guard let best = scores.indices.min(by: { scores[$0] < scores[$1] }) else {
            return ScrollAlignment(offset: 0, confidence: 0, overlappingRows: 0)
        }

        return ScrollAlignment(
            offset: best,
            confidence: confidence(of: scores, best: best),
            overlappingRows: bodyHeight - best
        )
    }

    /// How much better the winning offset is than the best rival.
    ///
    /// Rivals adjacent to the winner are ignored: a good match at offset 200 also scores
    /// well at 199, and counting that as competition would report every correct alignment
    /// as uncertain. What matters is whether somewhere *else* entirely matched almost as
    /// well, which is exactly what repetitive content does.
    private static func confidence(of scores: [Float], best: Int) -> Double {
        let exclusion = 8
        var rival = Float.greatestFiniteMagnitude
        for (offset, score) in scores.enumerated() where abs(offset - best) > exclusion {
            rival = min(rival, score)
        }

        let winner = scores[best]
        // A perfect match with no rival at all: the page is unambiguous.
        guard rival < .greatestFiniteMagnitude else { return winner < sameRowTolerance ? 1 : 0.5 }
        guard rival > 0 else { return 0 }

        // Ratio rather than difference, so the number means the same thing on a dense
        // screenshot and on a mostly-white page.
        let separation = Double(1 - winner / rival)
        return min(max(separation, 0), 1)
    }
}
