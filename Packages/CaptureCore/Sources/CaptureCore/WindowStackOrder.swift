import CoreGraphics
import Foundation

/// Which window is in front of which (docs/03 §1.2).
///
/// Window-pick mode hit-tests front to back, and it used to take that order from
/// `SCShareableContent`. ScreenCaptureKit makes no promise about the order of its window
/// list, and in practice it is not the stacking order — so hovering a window could
/// highlight, and capture, one behind it. The window server's own list is front to back by
/// definition, so the snapshot is re-ordered by it.
///
/// Metadata only: `CGWindowListCopyWindowInfo` reads IDs, alpha and layers and returns no
/// pixels, so this is not the deprecated CG capture path CLAUDE.md rule 3 rules out.
public enum WindowStackOrder {
    /// A window's place in the stack. Lower is further forward.
    public struct Entry: Sendable, Hashable {
        public let rank: Int
        public let alpha: Double

        public init(rank: Int, alpha: Double) {
            self.rank = rank
            self.alpha = alpha
        }
    }

    /// The on-screen windows, front to back, from the window server.
    public static func current() -> [CGWindowID: Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        return entries(from: list)
    }

    /// The same, from the window server's dictionaries. Split out so it can be tested.
    static func entries(from list: [[String: Any]]) -> [CGWindowID: Entry] {
        var result: [CGWindowID: Entry] = [:]
        for (rank, info) in list.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            result[CGWindowID(number.uint32Value)] = Entry(rank: rank, alpha: alpha)
        }
        return result
    }

    /// `windows` front to back, without the ones nobody can see or pick.
    ///
    /// - Parameters:
    ///   - stack: the window server's order; windows it does not know keep their relative
    ///     order after every window it does, so a stale list still hit-tests sensibly.
    ///   - excluded: Kadr's own overlay panels, which must never be picked in place of the
    ///     window underneath them.
    public static func ordered(
        _ windows: [WindowInfo],
        stack: [CGWindowID: Entry],
        excluding excluded: Set<CGWindowID> = []
    ) -> [WindowInfo] {
        windows.enumerated()
            .filter { !excluded.contains($0.element.id) }
            // A fully transparent window covers the screen for some utilities and would
            // otherwise win every hit test while showing nothing.
            .filter { (stack[$0.element.id]?.alpha ?? 1) > 0.01 }
            .sorted { lhs, rhs in
                let left = stack[lhs.element.id]?.rank ?? Int.max
                let right = stack[rhs.element.id]?.rank ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }
}
