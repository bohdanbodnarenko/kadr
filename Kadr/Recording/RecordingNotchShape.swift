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

/// Dynamic Island silhouette (macos-notch-ui).
///
/// Full width along the top edge, then concave “ears” that curve in to the body — the same
/// inverse corner the hardware notch has, so the shell reads as the notch growing rather
/// than a black slab pasted under it — and convex rounded corners at the bottom. Both radii
/// animate, so compact → expanded → hidden is one continuous shape.
struct RecordingNotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 8, bottomCornerRadius: CGFloat = 12) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topCornerRadius, rect.width / 4, rect.height / 2))
        let bottom = max(0, min(bottomCornerRadius, (rect.width - 2 * top) / 2, rect.height - top))
        let left = rect.minX + top
        let right = rect.maxX - top

        var path = Path()
        // A 1-pt bleed above the rect: the shell is flush with the display edge, and an
        // anti-aliased top edge would leave a hairline of wallpaper over the notch.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY - 1))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.minY + top),
            control: CGPoint(x: left, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: left + bottom, y: rect.maxY),
            control: CGPoint(x: left, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.maxY - bottom),
            control: CGPoint(x: right, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: right, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - 1))
        path.closeSubpath()
        return path
    }
}
