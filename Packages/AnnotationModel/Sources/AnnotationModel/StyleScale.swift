import CoreGraphics
import Foundation

/// Stroke and badge sizes relative to a 1440 pt canvas (docs/16 ED-13).
public enum StyleScale: Sendable {
    public static let referenceLongestEdge: CGFloat = 1440

    public static func factor(for canvasSize: CGSize) -> CGFloat {
        let longest = max(canvasSize.width, canvasSize.height)
        guard longest > 0 else { return 1 }
        return min(max(longest / referenceLongestEdge, 0.75), 3)
    }

    public static func scaled(_ value: CGFloat, for canvasSize: CGSize) -> CGFloat {
        value * factor(for: canvasSize)
    }
}
