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

/// Notch-docked shell: flat against the screen top, pill ears only at the bottom.
///
/// Concave top “island ears” nicked the menu bar on a wide countdown strip — the
/// hardware notch already supplies the top edge, so the panel must not cut itself
/// away from it. A 1-pt bleed above the view kills the anti-aliased hairline.
struct RecordingNotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 0, bottomCornerRadius: CGFloat = 16) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    static func forShell(height: CGFloat) -> RecordingNotchShape {
        let clamped = max(height, 24)
        return RecordingNotchShape(
            topCornerRadius: 0,
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
        let radius = min(bottomCornerRadius, rect.height / 2, rect.width / 2)
        var bleed = rect
        bleed.origin.y -= 1
        bleed.size.height += 1
        return UnevenRoundedRectangle(
            topLeadingRadius: topCornerRadius,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: topCornerRadius,
            style: .continuous
        ).path(in: bleed)
    }
}
