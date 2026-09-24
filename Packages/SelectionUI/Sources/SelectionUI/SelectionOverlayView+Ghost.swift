import AppKit
import Shared

/// The last captured area, drawn as a dashed ghost until the user starts dragging.
///
/// Split from the view because the live selection path is already the hot 120 Hz redraw,
/// and the ghost is a hint, not part of that interaction.
extension SelectionOverlayView {
    func addGhostLayers(to root: CALayer) {
        ghostLayer.frame = bounds
        ghostLayer.fillColor = NSColor.white.withAlphaComponent(0.06).cgColor
        ghostLayer.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        ghostLayer.lineWidth = 1
        ghostLayer.lineDashPattern = [6, 4]
        ghostLayer.isHidden = true
        root.addSublayer(ghostLayer)

        ghostLabelLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        ghostLabelLayer.fontSize = 11
        ghostLabelLayer.foregroundColor = NSColor.white.cgColor
        ghostLabelLayer.alignmentMode = .center
        ghostLabelLayer.contentsScale = displayScale.factor
        ghostLabelLayer.isHidden = true
        root.addSublayer(ghostLabelLayer)
    }

    /// Hidden the moment a drag starts: two overlapping rectangles is noise, and the live
    /// selection is the one that matters.
    func updateGhost() {
        guard let ghost = lastRegionGhost, !ghost.isEmpty,
              interaction.rect == nil || interaction.rect?.isEmpty == true
        else {
            hideGhost()
            return
        }
        ghostLayer.path = CGPath(rect: ghost, transform: nil)
        ghostLayer.isHidden = false
        let widthPx = Int((ghost.width * displayScale.factor).rounded())
        let heightPx = Int((ghost.height * displayScale.factor).rounded())
        let text = "\(widthPx) × \(heightPx)  ·  Return repeats last area"
        ghostLabelLayer.string = text
        let width = Self.badgeWidth(for: text)
        ghostLabelLayer.frame = CGRect(
            x: ghost.midX - width / 2,
            y: ghost.minY - Self.badgeHeight - 6,
            width: width,
            height: Self.badgeHeight
        )
        ghostLabelLayer.isHidden = ghostLabelLayer.frame.minY < 0
    }

    func hideGhost() {
        ghostLayer.isHidden = true
        ghostLabelLayer.isHidden = true
    }
}
