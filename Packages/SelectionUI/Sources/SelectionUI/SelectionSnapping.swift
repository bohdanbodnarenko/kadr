import CoreGraphics
import Shared

/// The lines in the frozen screen a selection sticks to (docs/03 §8.3, docs/06 M21).
///
/// Lining a screenshot up with a window's border by hand costs a dozen nudges and usually
/// ends a pixel out. The freeze already contains the answer — the border is right there in
/// the bitmap — so the selection is pulled onto it.
///
/// Deliberately a value: the detection happens once per display, off the drag path, and
/// what the interaction holds is the answer rather than the image.
public struct SelectionSnapping: Equatable, Sendable {
    public var candidates: EdgeCandidates
    /// Pixels per point on this display.
    public var scale: CGFloat
    /// How close an edge has to be before it snaps, in points.
    public var tolerance: CGFloat

    public init(candidates: EdgeCandidates, scale: CGFloat, tolerance: CGFloat = 6) {
        self.candidates = candidates
        self.scale = scale
        self.tolerance = tolerance
    }

    public var isEmpty: Bool {
        candidates.isEmpty || tolerance <= 0
    }

    /// Pulls a selection rect onto nearby edges.
    ///
    /// - Parameter rect: display-local points, top-left origin — the same space the
    ///   selection lives in, and the same orientation as the frozen image (rule 6).
    public func snapped(_ rect: CGRect) -> CGRect {
        guard !isEmpty, !rect.isEmpty else { return rect }

        let pixels = PixelRect(
            x: Int((rect.minX * scale).rounded()),
            y: Int((rect.minY * scale).rounded()),
            width: Int((rect.width * scale).rounded()),
            height: Int((rect.height * scale).rounded())
        )
        let snapped = EdgeSnapper.snapped(
            pixels,
            to: candidates,
            tolerance: Int((tolerance * scale).rounded())
        )
        guard snapped != pixels else { return rect }

        return CGRect(
            x: CGFloat(snapped.x) / scale,
            y: CGFloat(snapped.y) / scale,
            width: CGFloat(snapped.width) / scale,
            height: CGFloat(snapped.height) / scale
        )
    }
}
