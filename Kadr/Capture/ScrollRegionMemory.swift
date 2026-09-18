import CoreGraphics
import Foundation

/// The last scrolling-capture frame, per display, across launches (docs/03 §1.6).
///
/// Sizing a frame over a page is work — the width of an article, the column of a thread —
/// and it was thrown away every time the app quit, so the second capture of the same page
/// started from a guess again. Kept per display, because the frame that fits a page on a
/// laptop screen is not the one that fits it on a 32-inch monitor.
///
/// Its own store rather than `AppSettings`: this is a scratch position, not a preference
/// anyone would look for in Settings, and it is written on every drag.
nonisolated enum ScrollRegionMemory {
    static let defaultsKey = "capture.scrollRegions"

    /// The remembered frame for a display, or nil when there is none that still fits.
    ///
    /// - Parameter visible: the screen's visible frame in the same space the rect was
    ///   stored in. A frame from a monitor that has since been unplugged, or from before
    ///   the Dock moved, is dropped rather than restored half off the screen.
    static func rect(
        forDisplay displayID: CGDirectDisplayID,
        visible: CGRect,
        defaults: UserDefaults = .standard
    ) -> CGRect? {
        guard let rect = stored(defaults: defaults)[String(displayID)]?.cgRect else { return nil }
        return ScrollRegionGeometry.fits(rect, in: visible) ? rect : nil
    }

    static func remember(
        _ rect: CGRect,
        forDisplay displayID: CGDirectDisplayID,
        defaults: UserDefaults = .standard
    ) {
        var table = stored(defaults: defaults)
        table[String(displayID)] = Frame(rect)
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    private static func stored(defaults: UserDefaults) -> [String: Frame] {
        guard let data = defaults.data(forKey: defaultsKey),
              let table = try? JSONDecoder().decode([String: Frame].self, from: data)
        else {
            return [:]
        }
        return table
    }

    /// `CGRect` is `Codable`, but its encoding is nested arrays — unreadable in a plist
    /// somebody is debugging, and brittle if the shape ever changes.
    private struct Frame: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }
}
