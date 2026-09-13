import CoreGraphics

/// CleanShot-style 1-based display addressing for the URL scheme and CLI.
///
/// Index `1` is the primary display — the screen with the menu bar, which AppKit lists
/// first in `NSScreen.screens`. Further indices follow that same order. Coordinates
/// passed with `display=` are local to that display: `(0, 0)` is its bottom-left
/// corner, matching CleanShot §20.
public enum DisplayIndex {
    /// The screen at a 1-based index, or `nil` when the Mac does not have that many.
    public static func screen(atOneBased index: Int, screens: [ScreenRect]) -> ScreenRect? {
        guard index >= 1, index <= screens.count else { return nil }
        return screens[index - 1]
    }

    /// Interprets `local` as a rect whose origin is the bottom-left of `display`.
    public static func globalize(local: ScreenRect, on display: ScreenRect) -> ScreenRect {
        ScreenRect(
            x: display.minX + local.minX,
            y: display.minY + local.minY,
            width: local.width,
            height: local.height
        )
    }
}
