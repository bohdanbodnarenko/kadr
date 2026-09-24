import AppKit
import Shared

/// The overlay's colour-picking mode (docs/03 §3 P3, docs/06 M22).
///
/// Split from the view because the eyedropper is a distinct answer the overlay can give —
/// a value rather than a rectangle — and reading it next to the selection drawing code
/// helped nobody.
extension SelectionOverlayView {
    /// What the eyedropper would report right now, or nil when there is nothing under
    /// the pointer to read.
    var currentPick: ColorPick? {
        guard let pointer = interaction.pointer, let colour = loupe.color(at: pointer) else {
            return nil
        }
        return ColorPick(color: colour.rgb, comparison: comparisonColor, format: colorFormat)
    }

    /// A click in eyedropper mode: what the hint promises ("Click to copy", T-CAP-1).
    func pickColor(at point: CGPoint) {
        interaction.pointerMoved(to: point)
        guard let pick = currentPick else { return }
        onPickColor?(pick)
    }

    /// Stores the colour under the pointer as the one to measure contrast against.
    func sampleComparisonColor() {
        guard let pointer = interaction.pointer, let colour = loupe.color(at: pointer) else { return }
        comparisonColor = colour.rgb
        redraw()
    }

    func setEyedropperMode(_ enabled: Bool) {
        guard enabled != isEyedropperMode else { return }
        isEyedropperMode = enabled
        if !enabled {
            comparisonColor = nil
        }
        redraw()
    }

    /// The loupe's readout while the eyedropper is on: the colour, and the contrast
    /// against the stored sample once there is one.
    var eyedropperReadout: String? {
        guard isEyedropperMode, let pick = currentPick else { return nil }
        return [pick.text, pick.contrastText].compactMap(\.self).joined(separator: "  ")
    }
}
