import SwiftUI

/// The playhead as a pin you can grab, not a 1.5-point line you have to aim at.
///
/// A crown above the ruler does the catching; the needle itself ignores clicks, so trims
/// and zooms underneath still work. The playhead used to be `allowsHitTesting(false)` on
/// the line alone, so the only way to scrub was to drag the ruler or a clip — which is how
/// a timeline feels raw.
///
/// Takes the playhead clock rather than a time, so it is the view that re-renders while
/// playback moves the playhead — not the timeline that contains it (docs/11 S2).
struct StudioTimelinePlayhead: View {
    let clock: StudioPlayhead
    let scale: CGFloat
    let height: CGFloat
    let duration: TimeInterval
    let onScrub: (TimeInterval) -> Void

    static let coordinateSpace = "studio.timeline.bands"
    static let crownLaneHeight: CGFloat = 14

    private enum Metrics {
        static let crownWidth: CGFloat = 11
        static let crownHeight: CGFloat = 13
        static let hitWidth: CGFloat = 26
        static let hitHeight: CGFloat = 22
        static let lineWidth: CGFloat = 1.5
    }

    var body: some View {
        let x = clock.time * scale
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: Metrics.lineWidth, height: max(0, height - Metrics.crownHeight + 2))
                .offset(x: x - Metrics.lineWidth / 2, y: Metrics.crownHeight - 2)
                .allowsHitTesting(false)

            Color.clear
                .frame(width: Metrics.hitWidth, height: Metrics.hitHeight)
                .contentShape(Rectangle())
                .overlay(alignment: .top) {
                    PlayheadCrownShape()
                        .fill(Color.accentColor)
                        .frame(width: Metrics.crownWidth, height: Metrics.crownHeight)
                        .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                }
                .offset(x: x - Metrics.hitWidth / 2)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpace))
                        .onChanged { value in
                            onScrub(Self.time(atX: value.location.x, scale: scale, duration: duration))
                        }
                )
                .help("Drag to scrub")
                .accessibilityLabel("Playhead")
        }
    }

    /// Edited time under a point on the timeline, clamped to the recording.
    static func time(atX x: CGFloat, scale: CGFloat, duration: TimeInterval) -> TimeInterval {
        guard scale > 0, duration > 0 else { return 0 }
        return min(max(Double(x / scale), 0), duration)
    }
}

/// A rounded flag with a tail pointing at the frame under the playhead.
struct PlayheadCrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tail = rect.height * 0.32
        let body = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: max(rect.height - tail, 1)
        )
        var path = Path(roundedRect: body, cornerRadius: min(2.5, body.width / 3))
        path.move(to: CGPoint(x: body.minX, y: body.maxY - 0.4))
        path.addLine(to: CGPoint(x: body.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - 0.4))
        path.closeSubpath()
        return path
    }
}
