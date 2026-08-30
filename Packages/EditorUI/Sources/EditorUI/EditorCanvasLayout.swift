import CoreGraphics
import Foundation

/// How the capture sits in the editor viewport (docs/03 §3, docs/06 M7).
///
/// Pure geometry: the scroll view applies these numbers, the tests prove them. A screenshot
/// that opens at 100% in the top-left of a large window looks unfinished; fitting it in the
/// remaining space and centering it is the workspace every annotator expects.
enum EditorCanvasLayout {
    static let minMagnification: CGFloat = 0.1
    static let maxMagnification: CGFloat = 8
    /// Room around the capture so it does not kiss the toolbar, inspector or zoom HUD.
    static let padding = EditorCanvasPadding(top: 36, leading: 40, bottom: 64, trailing: 40)
    /// Extra inset while cropping so the eight handles stay on-screen at the image edge
    /// (docs/08 §2, docs/09 U1.8).
    static let cropHandleMargin: CGFloat = 26
    /// A stitched page is several widths tall; fitting both axes would shrink it to a strip.
    static let tallPageAspect: CGFloat = 2

    /// Scale that shows the whole canvas inside `viewport`, leaving `padding` (and the crop
    /// handle gutter, when cropping).
    static func fitMagnification(
        canvas: CGSize,
        viewport: CGSize,
        padding: EditorCanvasPadding = padding,
        isCropping: Bool = false,
        isTallPage: Bool? = nil
    ) -> CGFloat {
        guard canvas.width > 0, canvas.height > 0, viewport.width > 0, viewport.height > 0 else {
            return 1
        }

        let extra = isCropping ? cropHandleMargin : 0
        let available = CGSize(
            width: max(viewport.width - padding.leading - padding.trailing - extra * 2, 1),
            height: max(viewport.height - padding.top - padding.bottom - extra * 2, 1)
        )
        let tall = isTallPage ?? Self.isTallPage(canvas)
        let scale: CGFloat = if tall {
            available.width / canvas.width
        } else {
            min(available.width / canvas.width, available.height / canvas.height)
        }
        return clampMagnification(scale)
    }

    static func isTallPage(_ canvas: CGSize) -> Bool {
        canvas.width > 0 && canvas.height > canvas.width * tallPageAspect
    }

    static func clampMagnification(_ value: CGFloat) -> CGFloat {
        min(max(value, minMagnification), maxMagnification)
    }

    static func zoomPercent(for magnification: CGFloat) -> Int {
        max(1, Int((magnification * 100).rounded()))
    }

    /// Whether the scaled canvas is larger than the viewport on either axis.
    static func canPan(canvas: CGSize, viewport: CGSize, magnification: CGFloat) -> Bool {
        canvas.width * magnification > viewport.width + 0.5
            || canvas.height * magnification > viewport.height + 0.5
    }

    /// Clip-view origin that keeps a smaller document centered and a larger one clamped.
    ///
    /// `proposed` is what AppKit would scroll to (a drag, a magnification pivot). When the
    /// document is smaller than the clip on an axis we ignore it and sit in the middle —
    /// otherwise a 400-pt capture lives in the top-left of an 1100-pt window.
    static func clipOrigin(
        document: CGSize,
        clip: CGSize,
        proposed: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: origin(document: document.width, clip: clip.width, proposed: proposed.x),
            y: origin(document: document.height, clip: clip.height, proposed: proposed.y)
        )
    }

    private static func origin(document: CGFloat, clip: CGFloat, proposed: CGFloat) -> CGFloat {
        let slack = document - clip
        if slack < 0 {
            return slack / 2
        }
        return min(max(proposed, 0), slack)
    }
}

/// Insets around the capture, in the viewport's points.
struct EditorCanvasPadding: Equatable, Sendable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat
}
