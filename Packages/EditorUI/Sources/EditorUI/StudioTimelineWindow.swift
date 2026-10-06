import SwiftUI

/// The stretch of a zoomed timeline worth drawing (docs/18 STU-15).
///
/// A 30-minute recording at full zoom is a lane hundreds of thousands of points wide. The
/// filmstrip used to lay out and decode a tile for all of it, or stretch 240 tiles across
/// it; now it draws only the tiles under the viewport, plus one viewport either side so a
/// scroll finds them already there.
enum StudioTimelineWindow {
    /// How far the window moves before it is recomputed, so scrolling does not re-request
    /// tiles on every point of travel.
    static let quantum: CGFloat = 64

    /// The content range to draw, given how far the content has scrolled (`origin` is the
    /// content's leading edge in viewport coordinates, so ≤ 0 once scrolled).
    static func visibleRange(origin: CGFloat, viewportWidth: CGFloat) -> ClosedRange<CGFloat> {
        let scrolled = max(-origin, 0)
        let snapped = (scrolled / quantum).rounded(.down) * quantum
        let lower = max(snapped - viewportWidth, 0)
        let upper = snapped + viewportWidth * 2 + quantum
        return lower ... upper
    }

    /// Tile indices a lane `width` points wide, split into `count` tiles, should draw for a
    /// lane-local `visible` range. Grown to whole chunks so small scrolls reuse a request.
    static func tileIndices(
        visible: ClosedRange<CGFloat>?,
        width: CGFloat,
        count: Int,
        chunk: Int = 32
    ) -> Range<Int> {
        guard count > 0 else { return 0 ..< 0 }
        guard let visible else { return 0 ..< count }
        let tile = width / CGFloat(count)
        guard tile > 0, visible.upperBound > 0, visible.lowerBound < width else { return 0 ..< 0 }
        let first = max(Int((visible.lowerBound / tile).rounded(.down)), 0) / chunk * chunk
        let last = min((Int((visible.upperBound / tile).rounded(.down)) / chunk + 1) * chunk, count)
        return first ..< max(first, last)
    }
}

/// Reports how far the timeline content has scrolled.
struct TimelineScrollOriginKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Publishes this content's leading edge in the timeline viewport's coordinates.
    func reportsTimelineScrollOrigin() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TimelineScrollOriginKey.self,
                    value: geometry.frame(in: .named(PlayheadFollower.viewportSpace)).minX
                )
            }
        }
    }
}
