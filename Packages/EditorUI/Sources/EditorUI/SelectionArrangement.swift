import CoreGraphics

/// Align and distribute for a selection (docs/18 ED-7).
///
/// Pure geometry: given each item's bounds, how far to move each one. Kept apart from the
/// model so the rules are table-tested, and so the move goes through the same translate
/// and undo path as a drag.
public enum SelectionArrangement {
    public enum Alignment: Int, CaseIterable, Sendable {
        case left, centerX, right, top, middle, bottom
    }

    public enum Axis: Int, CaseIterable, Sendable {
        case horizontal, vertical
    }

    /// The moves that line items up on one edge or centre.
    ///
    /// Several items align to the bounds of the whole selection, as in Keynote. A single item
    /// has nothing to align to but the canvas, so it aligns to `canvas`.
    public static func align(
        _ boxes: [CGRect],
        _ alignment: Alignment,
        canvas: CGRect
    ) -> [CGSize] {
        guard !boxes.isEmpty else { return [] }
        let reference = boxes.count == 1 ? canvas : union(boxes)
        return boxes.map { box in
            switch alignment {
            case .left: CGSize(width: reference.minX - box.minX, height: 0)
            case .centerX: CGSize(width: reference.midX - box.midX, height: 0)
            case .right: CGSize(width: reference.maxX - box.maxX, height: 0)
            case .top: CGSize(width: 0, height: reference.minY - box.minY)
            case .middle: CGSize(width: 0, height: reference.midY - box.midY)
            case .bottom: CGSize(width: 0, height: reference.maxY - box.maxY)
            }
        }
    }

    /// The moves that leave equal gaps between items along `axis`, keeping the first and
    /// last item where they are. Fewer than three items have nothing to distribute.
    public static func distribute(_ boxes: [CGRect], along axis: Axis) -> [CGSize] {
        guard boxes.count >= 3 else { return boxes.map { _ in .zero } }
        let start: (CGRect) -> CGFloat = axis == .horizontal ? { $0.minX } : { $0.minY }
        let length: (CGRect) -> CGFloat = axis == .horizontal ? { $0.width } : { $0.height }
        let order = boxes.indices.sorted { start(boxes[$0]) < start(boxes[$1]) }
        let first = boxes[order[0]]
        let last = boxes[order[order.count - 1]]
        let span = start(last) + length(last) - start(first)
        let occupied = order.reduce(0) { $0 + length(boxes[$1]) }
        let gap = (span - occupied) / CGFloat(boxes.count - 1)

        var moves = boxes.map { _ in CGSize.zero }
        var cursor = start(first)
        for index in order {
            let shift = cursor - start(boxes[index])
            moves[index] = axis == .horizontal
                ? CGSize(width: shift, height: 0)
                : CGSize(width: 0, height: shift)
            cursor += length(boxes[index]) + gap
        }
        return moves
    }

    private static func union(_ boxes: [CGRect]) -> CGRect {
        boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
    }
}
