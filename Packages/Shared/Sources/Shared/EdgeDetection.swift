import CoreGraphics
import Foundation

/// The straight edges found in an image, in pixels (docs/03 §3 P3, docs/06 M21).
///
/// Only *long* edges are kept, and that is the whole idea: what a user wants to measure
/// or snap to on a screenshot is a window border, a sidebar divider, a table rule — lines
/// that run most of the way across the region. Texture and text produce short gradients
/// everywhere, so a general-purpose edge detector would offer a thousand useless
/// candidates and snap to the wrong one.
public struct EdgeCandidates: Sendable, Hashable {
    /// x positions of vertical edges, ascending.
    public let verticalEdges: [Int]
    /// y positions of horizontal edges, ascending. Top-left origin, like the image.
    public let horizontalEdges: [Int]
    public let pixelSize: PixelSize

    public init(verticalEdges: [Int], horizontalEdges: [Int], pixelSize: PixelSize) {
        self.verticalEdges = verticalEdges
        self.horizontalEdges = horizontalEdges
        self.pixelSize = pixelSize
    }

    public static let none = EdgeCandidates(
        verticalEdges: [],
        horizontalEdges: [],
        pixelSize: PixelSize(width: 0, height: 0)
    )

    public var isEmpty: Bool {
        verticalEdges.isEmpty && horizontalEdges.isEmpty
    }
}

/// How hard to look for edges.
public struct EdgeDetectionOptions: Sendable, Hashable {
    /// Minimum 8-bit luminance step across the boundary for a pixel to count.
    public var contrast: Int
    /// Fraction of the image's height (or width) that must show the step before the
    /// line is called an edge. High on purpose: this is what filters out text.
    public var coverage: Double
    /// Edges closer together than this collapse to one, so an anti-aliased two-pixel
    /// border does not become two competing snap targets.
    public var minimumSeparation: Int

    public init(contrast: Int = 24, coverage: Double = 0.55, minimumSeparation: Int = 3) {
        self.contrast = contrast
        self.coverage = coverage
        self.minimumSeparation = minimumSeparation
    }

    public static let `default` = EdgeDetectionOptions()
}

/// Finds the long straight edges in a grayscale bitmap.
///
/// Deliberately simple: one pass counting luminance steps per column and per row. It is
/// O(width × height) with no allocations per pixel, which matters because it runs on a
/// full 5K freeze between the user pressing a hotkey and the overlay appearing.
public enum EdgeDetector {
    /// - Parameters:
    ///   - grayscale: 8-bit luminance, row-major, top-left origin.
    ///   - bytesPerRow: may exceed `width`, as `CGContext` rows usually do.
    public static func candidates(
        grayscale: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        options: EdgeDetectionOptions = .default
    ) -> EdgeCandidates {
        guard width > 1, height > 1 else { return .none }

        var columnCounts = [Int](repeating: 0, count: width)
        var rowCounts = [Int](repeating: 0, count: height)

        for y in 0 ..< height {
            let row = grayscale + y * bytesPerRow
            let previousRow = y > 0 ? grayscale + (y - 1) * bytesPerRow : nil
            for x in 0 ..< width {
                let value = Int(row[x])
                if x > 0, abs(value - Int(row[x - 1])) >= options.contrast {
                    columnCounts[x] += 1
                }
                if let previousRow, abs(value - Int(previousRow[x])) >= options.contrast {
                    rowCounts[y] += 1
                }
            }
        }

        let verticalThreshold = Int((Double(height) * options.coverage).rounded())
        let horizontalThreshold = Int((Double(width) * options.coverage).rounded())

        return EdgeCandidates(
            verticalEdges: collapse(
                columnCounts.indices.filter { columnCounts[$0] >= max(1, verticalThreshold) },
                separation: options.minimumSeparation,
                strength: { columnCounts[$0] }
            ),
            horizontalEdges: collapse(
                rowCounts.indices.filter { rowCounts[$0] >= max(1, horizontalThreshold) },
                separation: options.minimumSeparation,
                strength: { rowCounts[$0] }
            ),
            pixelSize: PixelSize(width: width, height: height)
        )
    }

    /// Reads an image as 8-bit luminance and finds its edges.
    ///
    /// Convenience for callers holding a `CGImage` — the frozen display in the overlay,
    /// the base image in the editor.
    public static func candidates(
        in image: CGImage,
        options: EdgeDetectionOptions = .default
    ) -> EdgeCandidates {
        let width = image.width
        let height = image.height
        guard width > 1, height > 1 else { return .none }

        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return .none }

        return pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return EdgeCandidates.none }
            return candidates(
                grayscale: base,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                options: options
            )
        }
    }

    /// Keeps the strongest line out of each cluster of adjacent ones.
    ///
    /// A one-pixel border on a Retina display is two or three pixels of gradient; without
    /// this the snapper would be choosing between three targets a pixel apart, which is
    /// indistinguishable from not snapping at all.
    static func collapse(
        _ positions: [Int],
        separation: Int,
        strength: (Int) -> Int
    ) -> [Int] {
        guard !positions.isEmpty else { return [] }
        var result: [Int] = []
        var cluster: [Int] = [positions[0]]

        func flush() {
            guard let best = cluster.max(by: { strength($0) < strength($1) }) else { return }
            result.append(best)
            cluster.removeAll(keepingCapacity: true)
        }

        for position in positions.dropFirst() {
            if let last = cluster.last, position - last <= separation {
                cluster.append(position)
            } else {
                flush()
                cluster.append(position)
            }
        }
        flush()
        return result
    }
}

/// Snapping a selection or a measurement to detected edges (docs/06 M21).
public enum EdgeSnapper {
    /// The nearest candidate within `tolerance`, or nil when nothing is close enough.
    public static func snapped(_ value: Int, to candidates: [Int], tolerance: Int) -> Int? {
        guard tolerance > 0 else { return nil }
        var best: (position: Int, distance: Int)?
        for candidate in candidates {
            let distance = abs(candidate - value)
            guard distance <= tolerance else { continue }
            if best == nil || distance < (best?.distance ?? .max) {
                best = (candidate, distance)
            }
        }
        return best?.position
    }

    /// Pulls each edge of a rect onto a detected line, independently.
    ///
    /// Independently on purpose: a selection is usually being lined up with two different
    /// things — a window's left border and a table's baseline — and moving the whole rect
    /// to satisfy one edge would break the other.
    public static func snapped(
        _ rect: PixelRect,
        to candidates: EdgeCandidates,
        tolerance: Int
    ) -> PixelRect {
        guard !candidates.isEmpty, tolerance > 0 else { return rect }
        let horizontal = span(
            from: rect.x,
            to: rect.x + rect.width,
            candidates: candidates.verticalEdges,
            tolerance: tolerance
        )
        let vertical = span(
            from: rect.y,
            to: rect.y + rect.height,
            candidates: candidates.horizontalEdges,
            tolerance: tolerance
        )
        return PixelRect(
            x: horizontal.min,
            y: vertical.min,
            width: horizontal.max - horizontal.min,
            height: vertical.max - vertical.min
        )
    }

    /// Snaps the two ends of one axis, refusing to collapse them onto each other.
    ///
    /// A thin selection drawn across a single border has both of its edges within
    /// tolerance of the same line. Snapping both would leave a zero-width rect, so the
    /// end that moved least keeps its snap and the other stays where the user put it.
    private static func span(
        from start: Int,
        to end: Int,
        candidates: [Int],
        tolerance: Int
    ) -> (min: Int, max: Int) {
        let snappedStart = snapped(start, to: candidates, tolerance: tolerance) ?? start
        let snappedEnd = snapped(end, to: candidates, tolerance: tolerance) ?? end
        if snappedEnd > snappedStart {
            return (snappedStart, snappedEnd)
        }
        let startMoved = abs(snappedStart - start)
        let endMoved = abs(snappedEnd - end)
        if startMoved <= endMoved, end > snappedStart {
            return (snappedStart, end)
        }
        if snappedEnd > start {
            return (start, snappedEnd)
        }
        return (start, end)
    }

    /// The box formed by the nearest detected lines on all four sides of a point.
    ///
    /// This is what "click a button and get its size" does: the enclosing rect of the UI
    /// element under the pointer, without asking the user to drag anything. The image's
    /// own bounds close any side with no edge beyond it.
    public static func enclosingRect(
        aroundX x: Int,
        y: Int,
        in candidates: EdgeCandidates
    ) -> PixelRect? {
        let width = candidates.pixelSize.width
        let height = candidates.pixelSize.height
        guard width > 0, height > 0, (0 ..< width).contains(x), (0 ..< height).contains(y) else {
            return nil
        }

        let left = candidates.verticalEdges.last { $0 <= x } ?? 0
        let right = candidates.verticalEdges.first { $0 > x } ?? width
        let top = candidates.horizontalEdges.last { $0 <= y } ?? 0
        let bottom = candidates.horizontalEdges.first { $0 > y } ?? height

        guard right > left, bottom > top else { return nil }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
