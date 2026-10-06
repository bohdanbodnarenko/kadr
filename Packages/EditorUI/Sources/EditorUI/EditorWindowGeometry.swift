import CoreGraphics
import Foundation

/// First-open size of the annotation window (docs/03 §3).
///
/// A 400-pt region capture in a canned 1100×720 window looks like a postage stamp even
/// after it is centered. The window should hug a small capture and back off to the screen
/// for a 5K one, then the canvas fits inside whatever is left.
public enum EditorWindowGeometry {
    /// The editor's floor. Mirrors `UXLayoutContract.editorMinimum` in the agent, which the
    /// editor cannot import; `KadrEditorTests` pins the two together (docs/14 UX-05).
    public static let minSize = CGSize(width: 760, height: 580)
    /// The studio window's floor, from the same contract (`studioMinimum`).
    public static let studioMinSize = CGSize(width: 820, height: 520)
    /// The inspector's resting width, and how far the user may drag it.
    ///
    /// An ideal rather than a fixed size now that the inspector is the system's own column:
    /// the window opens at this width and the divider moves from there. The bounds are what
    /// keeps a drag from collapsing the controls into an unreadable strip at one end or
    /// squeezing the canvas out at the other.
    public static let inspectorWidth: CGFloat = 268
    public static let inspectorMinWidth: CGFloat = 232
    public static let inspectorMaxWidth: CGFloat = 420
    public static let toolbarHeight: CGFloat = 52
    public static let screenFill: CGFloat = 0.92

    /// Content size before clamping to the display.
    public static func preferredContentSize(
        canvasSize: CGSize,
        inspectorVisible: Bool = true
    ) -> CGSize {
        let padding = EditorCanvasLayout.padding
        let inspector = inspectorVisible ? inspectorWidth : 0
        let width = canvasSize.width + padding.leading + padding.trailing + inspector
        let height = canvasSize.height + padding.top + padding.bottom + toolbarHeight
        return CGSize(
            width: max(width, minSize.width),
            height: max(height, minSize.height)
        )
    }

    /// A frame centered in `visibleFrame`, never larger than 92% of that screen.
    public static func preferredFrame(
        canvasSize: CGSize,
        on visibleFrame: CGRect,
        inspectorVisible: Bool = true
    ) -> CGRect {
        let desired = preferredContentSize(
            canvasSize: canvasSize,
            inspectorVisible: inspectorVisible
        )
        let maxSize = CGSize(
            width: max(visibleFrame.width * screenFill, minSize.width),
            height: max(visibleFrame.height * screenFill, minSize.height)
        )
        let size = CGSize(
            width: min(desired.width, maxSize.width),
            height: min(desired.height, maxSize.height)
        )
        return CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
