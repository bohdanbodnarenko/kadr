import CoreGraphics

/// Edge and centre snapping for a moving selection (docs/18 ED-7).
///
/// The moving box's left, centre and right are compared with the same three lines of every
/// target — the canvas and each annotation not being moved — and likewise top, middle and
/// bottom. The closest line within `threshold` wins on each axis independently, so a box can
/// snap its left edge to one thing and its middle to another.
public enum SnapGuides {
    /// A line the selection snapped to, in image points, for drawing a guide.
    public struct Guide: Hashable, Sendable {
        public enum Axis: Hashable, Sendable {
            /// A vertical line at `position` on the x axis.
            case vertical
            /// A horizontal line at `position` on the y axis.
            case horizontal
        }

        public var axis: Axis
        public var position: CGFloat

        public init(axis: Axis, position: CGFloat) {
            self.axis = axis
            self.position = position
        }
    }

    public struct Result: Equatable, Sendable {
        /// What to add to the proposed move so the box lands on the guides.
        public var adjustment: CGSize
        public var guides: [Guide]
    }

    /// Snaps `moving` (already at its proposed position) to `targets`.
    public static func snap(_ moving: CGRect, to targets: [CGRect], threshold: CGFloat) -> Result {
        let candidates = targets.filter { !$0.isNull && !$0.isInfinite }
        let horizontal = closest(
            lines(moving.minX, moving.midX, moving.maxX),
            candidates.flatMap { lines($0.minX, $0.midX, $0.maxX) },
            threshold: threshold
        )
        let vertical = closest(
            lines(moving.minY, moving.midY, moving.maxY),
            candidates.flatMap { lines($0.minY, $0.midY, $0.maxY) },
            threshold: threshold
        )
        var guides: [Guide] = []
        if let horizontal {
            guides.append(Guide(axis: .vertical, position: horizontal.target))
        }
        if let vertical {
            guides.append(Guide(axis: .horizontal, position: vertical.target))
        }
        return Result(
            adjustment: CGSize(width: horizontal?.offset ?? 0, height: vertical?.offset ?? 0),
            guides: guides
        )
    }

    private static func lines(_ low: CGFloat, _ mid: CGFloat, _ high: CGFloat) -> [CGFloat] {
        [low, mid, high]
    }

    private static func closest(
        _ moving: [CGFloat],
        _ targets: [CGFloat],
        threshold: CGFloat
    ) -> (offset: CGFloat, target: CGFloat)? {
        var best: (offset: CGFloat, target: CGFloat)?
        for line in moving {
            for target in targets {
                let offset = target - line
                guard abs(offset) <= threshold else { continue }
                if best == nil || abs(offset) < abs(best?.offset ?? .infinity) {
                    best = (offset, target)
                }
            }
        }
        return best
    }
}
