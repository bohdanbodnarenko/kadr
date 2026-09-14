import AppKit
import CoreGraphics
import Foundation

/// Size of the camera housing, from the display's own safe area and menu-bar split.
struct RecordingNotchMetrics: Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat

    /// Used when a notched layout is asked for without a live screen (tests, fallback).
    static let fallback = RecordingNotchMetrics(width: 180, height: 32)

    static func hardware(on screen: NSScreen) -> RecordingNotchMetrics {
        let height = max(screen.safeAreaInsets.top, 24)
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else {
            return RecordingNotchMetrics(width: fallback.width, height: height)
        }
        let gap = right.minX - left.maxX
        let width = gap > 80 ? gap : fallback.width
        return RecordingNotchMetrics(width: width, height: height)
    }
}

/// Dynamic Island geometry (macos-notch-ui): flush to the screen top, controls in the ears.
///
/// The shell is menu-bar height only. A non-interactive black band covers the camera;
/// every button lives in the left or right wing so nothing is hidden behind it.
struct RecordingNotchLayout: Equatable, Sendable {
    static let maxWindowWidth: CGFloat = 420
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

    var leftWingWidth: CGFloat {
        if hasPreRoll {
            return 188
        }
        return isExpanded ? 186 : 76
    }

    var rightWingWidth: CGFloat {
        hasPreRoll ? 72 : 58
    }

    var restIslandWidth: CGFloat {
        let wings = leftWingWidth + cameraReserveWidth + rightWingWidth
        if hasPreRoll {
            return max(360, wings)
        }
        return max(isExpanded ? 400 : 300, wings)
    }

    var islandWidth: CGFloat {
        isVisible ? restIslandWidth : 0
    }

    var windowSize: CGSize {
        CGSize(width: Self.maxWindowWidth, height: shellHeight)
    }
}
