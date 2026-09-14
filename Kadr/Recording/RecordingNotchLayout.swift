import AppKit
import CoreGraphics
import Foundation

/// Size of the camera housing, from the display's own menu-bar split.
struct RecordingNotchMetrics: Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat

    /// Used when a notched layout is asked for without a live screen (tests, fallback).
    static let fallback = RecordingNotchMetrics(width: 180, height: 32)

    static func hardware(on screen: NSScreen) -> RecordingNotchMetrics {
        // The menu-bar strip, not `safeAreaInsets.top`: that inset is taller than the
        // camera housing and made the shell a slab under the notch.
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else {
            let height = min(max(screen.safeAreaInsets.top, 24), 34)
            return RecordingNotchMetrics(width: fallback.width, height: height)
        }
        let height = min(max(left.height, 24), 34)
        let gap = right.minX - left.maxX
        let width = gap > 80 ? gap : fallback.width
        return RecordingNotchMetrics(width: width, height: height)
    }
}

/// Dynamic Island geometry (macos-notch-ui): flush to the screen top, controls in the ears.
///
/// The shell is menu-bar height only. A non-interactive band covers the camera;
/// every button lives in the left or right wing so nothing is hidden behind it.
struct RecordingNotchLayout: Equatable, Sendable {
    /// Inset from each rounded end so the first and last controls sit inside the ears,
    /// past the pill’s corner — not flush against the curve.
    static let endInset: CGFloat = 20
    /// Gap between a wing and the camera housing. Zero: the hardware reserve is
    /// already the camera, so extra pad here was a second empty strip.
    static let cameraSidePad: CGFloat = 0
    /// Extra left-wing width on hover — a small island breathe, not a full grow.
    static let hoverExpansion: CGFloat = 12
    static let controlSize: CGFloat = 22
    static let controlGap: CGFloat = 6
    /// Interactive row height — matches the menu-bar strip.
    static let contentHeight: CGFloat = 32
    /// Clear margin past each pill ear so the window’s square clip cannot flatten it.
    static var windowEarPad: CGFloat {
        RecordingNotchShape.forShell(height: contentHeight).bottomCornerRadius
    }

    var hardware: RecordingNotchMetrics
    var isExpanded: Bool
    var hasPreRoll: Bool
    var isVisible: Bool = true

    /// Menu-bar inset; also the shell height (no extra row below the notch).
    var stripHeight: CGFloat {
        hardware.height
    }

    var shellHeight: CGFloat {
        stripHeight
    }

    /// Width of the camera cutout the shell must cover (not hit-testable).
    var cameraReserveWidth: CGFloat {
        hardware.width
    }

    var notchShape: RecordingNotchShape {
        RecordingNotchShape.forShell(height: shellHeight)
    }

    private var wingInsets: CGFloat {
        Self.endInset + Self.cameraSidePad
    }

    var leftWingWidth: CGFloat {
        if hasPreRoll {
            return wingInsets + 20 + (3 * (Self.controlSize + Self.controlGap))
        }
        // Dot + elapsed time. Restart/discard stay in the More menu so the ear
        // does not grow a strip of empty black on hover.
        var content = 7 + Self.controlGap + 40 + Self.controlGap + Self.controlSize
        if isExpanded {
            content += Self.hoverExpansion
        }
        return wingInsets + content
    }

    var rightWingWidth: CGFloat {
        wingInsets + (2 * Self.controlSize) + Self.controlGap
    }

    var restIslandWidth: CGFloat {
        leftWingWidth + cameraReserveWidth + rightWingWidth
    }

    var islandWidth: CGFloat {
        isVisible ? restIslandWidth : 0
    }

    /// Leading space so the camera band stays on the hardware notch while a
    /// wing is wider than the other (countdown is left-heavy). Always at least
    /// `windowEarPad` so the left pill is not clipped to a square.
    var islandLeadingInset: CGFloat {
        max(0, (windowSize.width - cameraReserveWidth) / 2 - leftWingWidth)
    }

    /// The panel stays this size so hover can animate the island without moving the window.
    ///
    /// Wider than the island when the wings are unequal, plus ear pads, so the
    /// camera can sit on the display centre and the pill is not clipped square.
    var windowSize: CGSize {
        let widest = RecordingNotchLayout(
            hardware: hardware,
            isExpanded: true,
            hasPreRoll: hasPreRoll,
            isVisible: true
        )
        let wing = max(widest.leftWingWidth, widest.rightWingWidth)
        let pad = Self.windowEarPad * 2
        return CGSize(width: wing * 2 + widest.cameraReserveWidth + pad, height: shellHeight)
    }
}
