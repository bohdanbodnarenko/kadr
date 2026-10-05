import AppKit
import Shared

extension SelectionOverlayView {
    func updateHints() {
        hints.update(
            context: CaptureHintContext(
                purpose: purpose,
                mode: mode,
                phase: interaction.phase,
                isEyedropper: isEyedropperMode,
                isEnabled: showsCaptureHints && isActiveDisplay,
                confirmsSelection: confirmsSelection
            ),
            in: bounds
        )
    }
}
