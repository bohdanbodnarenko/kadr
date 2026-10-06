import ControlKit
import SwiftUI

/// The in and out marks on the timeline (docs/18 T-STU-11): the stretch outside them dimmed,
/// and a bracket at each mark, so the range reads without colour.
struct StudioTimelineMarks: View {
    let marks: StudioMarks
    let duration: TimeInterval
    let scale: CGFloat
    let height: CGFloat

    var body: some View {
        if let range = marks.range(duration: duration) {
            let start = range.lowerBound * scale
            let end = range.upperBound * scale
            let width = duration * scale
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(KadrFill.scrim)
                    .frame(width: start, height: height)
                Rectangle()
                    .fill(KadrFill.scrim)
                    .frame(width: max(width - end, 0), height: height)
                    .offset(x: end)
                bracket(opensRight: true)
                    .offset(x: start)
                bracket(opensRight: false)
                    .offset(x: end - 6)
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Marked range", bundle: .module))
            .accessibilityValue(Text(
                "\(StudioInspector.clock(range.lowerBound)) to \(StudioInspector.clock(range.upperBound))",
                bundle: .module
            ))
        }
    }

    /// `[` at the in mark, `]` at the out mark.
    private func bracket(opensRight: Bool) -> some View {
        Path { path in
            let edge: CGFloat = opensRight ? 0 : 6
            let tip: CGFloat = opensRight ? 6 : 0
            path.move(to: CGPoint(x: tip, y: 0))
            path.addLine(to: CGPoint(x: edge, y: 0))
            path.addLine(to: CGPoint(x: edge, y: height))
            path.addLine(to: CGPoint(x: tip, y: height))
        }
        .stroke(Color.accentColor, lineWidth: 2)
        .frame(width: 6, height: height)
    }
}
