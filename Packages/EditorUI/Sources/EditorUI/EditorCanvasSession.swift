import Foundation
import Observation

/// Zoom and fit state for one editor window.
///
/// View state, not document state: pinch, ⌘0 and Fit Canvas must not dirty the file.
@MainActor
@Observable
final class EditorCanvasSession {
    /// When true, the canvas re-fits every time the viewport or the capture size changes.
    var zoomToFit = true
    private(set) var magnification: CGFloat = 1

    var zoomPercent: Int {
        EditorCanvasLayout.zoomPercent(for: magnification)
    }

    func fit() {
        zoomToFit = true
    }

    func zoomIn() {
        setMagnification(magnification * 1.25)
    }

    func zoomOut() {
        setMagnification(magnification * 0.8)
    }

    func setPercent(_ percent: Int) {
        setMagnification(CGFloat(percent) / 100)
    }

    func setMagnification(_ value: CGFloat) {
        zoomToFit = false
        magnification = EditorCanvasLayout.clampMagnification(value)
    }

    /// Pinch and the scroll view report a live magnification; that leaves fit mode.
    func noteLiveMagnification(_ value: CGFloat) {
        zoomToFit = false
        magnification = EditorCanvasLayout.clampMagnification(value)
    }

    /// Fit-mode updates from the host, which already computed the scale.
    func noteFittedMagnification(_ value: CGFloat) {
        let clamped = EditorCanvasLayout.clampMagnification(value)
        guard abs(magnification - clamped) > 0.002 else { return }
        magnification = clamped
    }
}
