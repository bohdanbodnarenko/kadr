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
    /// Inset from each rounded end so the first and last controls sit inside the ears.
    static let endInset: CGFloat = 14
    static let cameraSidePad: CGFloat = 4
    static let controlSize: CGFloat = 22
    static let controlGap: CGFloat = 6
    /// Interactive row height — matches the menu-bar strip.
    static let contentHeight: CGFloat = 32

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
            content += Self.controlGap + 20
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

    /// The panel stays this size so hover can animate the island without moving the window.
    var windowSize: CGSize {
        let widest = RecordingNotchLayout(
            hardware: hardware,
            isExpanded: true,
            hasPreRoll: hasPreRoll,
            isVisible: true
        )
        return CGSize(width: widest.restIslandWidth, height: shellHeight)
    }
}
