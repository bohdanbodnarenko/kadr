import CoreGraphics

/// Declared minimums and compact presentation widths (docs/14 UX-05).
///
/// One table so layout tests and the windows that enforce them cannot drift. Values are
/// points at 1×; 2× displays scale the backing store, not these numbers.
enum UXLayoutContract {
    static let settingsMinimum = CGSize(width: 700, height: 540)
    static let historyMinimum = CGSize(width: 560, height: 360)
    static let editorMinimum = CGSize(width: 760, height: 580)
    static let studioMinimum = CGSize(width: 820, height: 520)
    static let onboardingMinimum = CGSize(width: 520, height: 560)
    static let overlayCardMinimumWidth: CGFloat = 140
    static let hitTargetMinimum: CGFloat = 20

    /// Compact All-in-One / Record setup strips keep Area, Window, Screen, and Record
    /// (or the three recording sources) plus overflow. This is the width they must still
    /// fit inside `visibleFrame`.
    static let compactHUDWidth: CGFloat = 320

    /// Displays the layout matrix must remain usable on, including the smallest
    /// supported laptop and a typical notched 14-inch.
    static let supportedVisibleFrames: [CGSize] = [
        CGSize(width: 1024, height: 640),
        CGSize(width: 1280, height: 720),
        CGSize(width: 1440, height: 810),
        CGSize(width: 1512, height: 850),
        CGSize(width: 1728, height: 980),
        CGSize(width: 2560, height: 1080)
    ]

    static func fits(_ size: CGSize, in visible: CGSize) -> Bool {
        size.width <= visible.width && size.height <= visible.height
    }
}
