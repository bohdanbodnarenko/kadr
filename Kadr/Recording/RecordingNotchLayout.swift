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

/// Dynamic Island geometry (macos-notch-ui).
///
/// * **Hidden** — exactly the hardware notch, so showing grows out of it and hiding shrinks
///   back into it instead of popping.
/// * **Compact** — menu-bar height, one status ear either side of the camera.
/// * **Expanded** — the same ears, plus a row of controls *below* the camera. Its width
///   follows the row's measured size (with a floor), never a hand-counted estimate.
///
/// The window is one fixed size that holds every state and the tooltip beneath, so the
/// shell animates inside it and the window never moves.
struct RecordingNotchLayout: Equatable, Sendable {
    /// Status ear either side of the camera: the dot on the left, the clock on the right.
    static let earWidth: CGFloat = 72
    /// Space between an ear's content and the shell edge, past the concave curve.
    static let earContentInset: CGFloat = 10
    static let rowHeight: CGFloat = 40
    static let rowTopGap: CGFloat = 2
    static let rowBottomPadding: CGFloat = 10
    static let rowSidePadding: CGFloat = 12
    /// So a short row still reads as an island, not a tab hanging off the notch.
    static let minimumExpandedWidth: CGFloat = 340
    /// The widest row the window is sized for.
    static let maximumExpandedWidth: CGFloat = 520
    /// Below the shell: tooltip pill, its gap and its shadow.
    static let tooltipReserve: CGFloat = 48
    /// Either side of and below the expanded shell, for its shadow.
    static let shadowReserve: CGFloat = 24

    var hardware: RecordingNotchMetrics
    var isExpanded: Bool
    var isVisible: Bool = true

    var showsRow: Bool {
        isVisible && isExpanded
    }

    /// Width of the menu-bar strip: the camera plus both ears, or just the camera when hidden.
    var stripWidth: CGFloat {
        isVisible ? hardware.width + 2 * Self.earWidth : hardware.width
    }

    var expandedHeight: CGFloat {
        hardware.height + Self.rowTopGap + Self.rowHeight + Self.rowBottomPadding
    }

    /// The floor under the shell's measured width.
    var minimumShellWidth: CGFloat {
        showsRow ? max(stripWidth, Self.minimumExpandedWidth) : stripWidth
    }

    var shellHeight: CGFloat {
        showsRow ? expandedHeight : hardware.height
    }

    var shape: RecordingNotchShape {
        if showsRow {
            return RecordingNotchShape(topCornerRadius: 14, bottomCornerRadius: 22)
        }
        if isVisible {
            return RecordingNotchShape(topCornerRadius: 8, bottomCornerRadius: 12)
        }
        return RecordingNotchShape(topCornerRadius: 6, bottomCornerRadius: 10)
    }

    /// Ear content inset from the shell edge.
    var earPadding: CGFloat {
        shape.topCornerRadius + Self.earContentInset
    }

    var windowSize: CGSize {
        CGSize(
            width: max(Self.maximumExpandedWidth, hardware.width + 2 * Self.earWidth)
                + 2 * Self.shadowReserve,
            height: expandedHeight + Self.tooltipReserve + Self.shadowReserve
        )
    }
}
