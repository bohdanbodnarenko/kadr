import AutomationKit
import Foundation

/// Settings a scrolling capture may override for one shot (CleanShot §20.3, docs/03 §8.4).
///
/// `nil` means "use the setting". The URL parameters `start` and `autoscroll` apply to
/// this capture only and are cleared when it reports back.
struct ScrollingOverrides: Sendable, Equatable {
    /// Whether Kadr synthesizes scroll events. `nil` uses Settings → Capture.
    var autoScroll: Bool?
    /// When `false` with a region, show the selection overlay instead of starting
    /// immediately. `nil` or `true` with a region starts frame capture at once.
    var startsImmediately: Bool?

    static let none = ScrollingOverrides()

    var isEmpty: Bool {
        self == .none
    }

    init(autoScroll: Bool? = nil, startsImmediately: Bool? = nil) {
        self.autoScroll = autoScroll
        self.startsImmediately = startsImmediately
    }

    init(_ options: CaptureOptions) {
        self.init(
            autoScroll: options.autoScroll,
            startsImmediately: options.startsImmediately
        )
    }
}
