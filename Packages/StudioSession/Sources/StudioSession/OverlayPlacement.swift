import CoreGraphics
import Foundation

/// Where a caption sits on the recording card (docs/09 U3.5).
///
/// A six-way grid rather than a free drag: keystroke pills and speech captions are chrome
/// on the frame, not part of the scene, and six slots is enough to keep them off the
/// camera bubble and off each other. Coordinates are top-left, matching `StudioCanvasLayout`.
public enum OverlayPlacement: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case topLeading
    case top
    case topTrailing
    case bottomLeading
    case bottom
    case bottomTrailing

    public var id: String {
        rawValue
    }

    public var isTop: Bool {
        switch self {
        case .topLeading, .top, .topTrailing: true
        case .bottomLeading, .bottom, .bottomTrailing: false
        }
    }

    /// Left / Centre / Right — the label on a two-row grid that already says Top or Bottom.
    public var title: String {
        switch self {
        case .topLeading, .bottomLeading: "Left"
        case .top, .bottom: "Centre"
        case .topTrailing, .bottomTrailing: "Right"
        }
    }

    /// The rectangle of `size` inside `bounds`, inset by `margin`.
    ///
    /// Clamped so a caption wider than the card still sits on it rather than hanging off
    /// into the padding.
    public func frame(for size: CGSize, in bounds: CGRect, margin: CGFloat) -> CGRect {
        let inset = max(margin, 0)
        let maxWidth = max(bounds.width - inset * 2, 1)
        let maxHeight = max(bounds.height - inset * 2, 1)
        let width = min(max(size.width, 1), maxWidth)
        let height = min(max(size.height, 1), maxHeight)
        let x: CGFloat = switch self {
        case .topLeading, .bottomLeading:
            bounds.minX + inset
        case .top, .bottom:
            bounds.midX - width / 2
        case .topTrailing, .bottomTrailing:
            bounds.maxX - inset - width
        }
        let y = isTop
            ? bounds.minY + inset
            : bounds.maxY - inset - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
