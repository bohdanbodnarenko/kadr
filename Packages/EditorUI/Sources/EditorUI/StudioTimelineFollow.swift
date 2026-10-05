import SwiftUI

/// Keeps a zoomed timeline showing the playhead while playback moves it (docs/18 STU-3).
///
/// It used to re-centre on every playhead change whenever the timeline was zoomed, playing
/// or not, so a scrub fought the pointer: the view slid under the needle being dragged.
/// Now it follows only during playback (every scrub pauses first, so a drag is never
/// followed), and it scrolls only when the needle leaves the visible range, paging it back
/// near the leading edge instead of pinning it to the centre on every frame.
///
/// A leaf inside the scrolled content, so the per-tick `onChange` lives in a body that has
/// nothing else to rebuild, and its own frame says how far the content has scrolled.
struct PlayheadFollower: View {
    let clock: StudioPlayhead
    let scale: CGFloat
    let viewportWidth: CGFloat
    let isFollowing: Bool
    let follow: () -> Void

    /// The scroll view's own coordinate space, which the content is measured against.
    static let viewportSpace = "studio.timeline.viewport"
    /// Where a page lands the needle: near the leading edge, so playback runs on into view.
    static let landing = UnitPoint(x: 0.1, y: 0.5)

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onChange(of: clock.time) {
                    guard isFollowing else { return }
                    let contentOrigin = geometry.frame(in: .named(Self.viewportSpace)).minX
                    if Self.needleIsOutOfView(
                        needleX: clock.time * scale + contentOrigin,
                        viewportWidth: viewportWidth
                    ) {
                        follow()
                    }
                }
        }
    }

    /// Whether the needle, in viewport coordinates, has left the visible range.
    ///
    /// A small margin on the trailing edge pages just before the needle disappears.
    static func needleIsOutOfView(needleX: CGFloat, viewportWidth: CGFloat, margin: CGFloat = 8) -> Bool {
        needleX < 0 || needleX > viewportWidth - margin
    }
}
