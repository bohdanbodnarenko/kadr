import AppKit
import SwiftUI

/// Whether any attached display reports a camera notch (`safeAreaInsets.top`).
enum RecordingNotchScreen {
    static var isAvailable: Bool {
        notchScreen != nil
    }

    static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    static var metrics: RecordingNotchMetrics {
        guard let screen = notchScreen else { return .fallback }
        return .hardware(on: screen)
    }
}

/// Dynamic Island silhouette: concave ears at the top, convex corners at the bottom.
///
/// The top edge is flat against the display so the shell continues the hardware notch
/// without a gap. Corner radii scale with total height so the ears stay subtle on a
/// short strip and read clearly when the shell extends below the camera.
struct RecordingNotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 10, bottomCornerRadius: CGFloat = 16) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    static func forShell(height: CGFloat) -> RecordingNotchShape {
        let clamped = max(height, 24)
        return RecordingNotchShape(
            topCornerRadius: min(10, clamped * 0.36),
            bottomCornerRadius: min(clamped * 0.5, 16)
        )
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(
            x: rect.minX + topCornerRadius,
            y: rect.maxY - bottomCornerRadius
        ))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(
            x: rect.maxX - topCornerRadius - bottomCornerRadius,
            y: rect.maxY
        ))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(
            x: rect.maxX - topCornerRadius,
            y: rect.minY + topCornerRadius
        ))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}
