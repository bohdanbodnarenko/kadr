import CoreGraphics
import Foundation

/// Where the user last dragged the capture island, across launches (docs/18 §4.2 P3).
///
/// Stored as the island's centre in fractions of the screen's visible frame rather than in
/// points, so a position chosen on one display lands in the same place on another, and a
/// Dock that moved cannot strand the island off screen.
nonisolated enum IslandPlacementMemory {
    static let defaultsKey = "capture.islandPosition"

    static func remember(_ frame: CGRect, in visible: CGRect, defaults: UserDefaults = .standard) {
        guard visible.width > 0, visible.height > 0 else { return }
        let fraction = [
            Double((frame.midX - visible.minX) / visible.width),
            Double((frame.midY - visible.minY) / visible.height)
        ]
        defaults.set(fraction, forKey: defaultsKey)
    }

    /// The remembered frame for an island of `size` on `visible`, kept wholly inside it,
    /// or nil when nothing was remembered.
    static func frame(for size: CGSize, in visible: CGRect, defaults: UserDefaults = .standard) -> CGRect? {
        guard let fraction = defaults.array(forKey: defaultsKey) as? [Double], fraction.count == 2,
              fraction.allSatisfy({ (0 ... 1).contains($0) })
        else { return nil }
        let midX = visible.minX + CGFloat(fraction[0]) * visible.width
        let midY = visible.minY + CGFloat(fraction[1]) * visible.height
        let x = min(max(midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(midY - size.height / 2, visible.minY), visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
