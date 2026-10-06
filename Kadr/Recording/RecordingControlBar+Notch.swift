import CoreGraphics
import SettingsKit

extension RecordingControlBar {
    /// Notch layout is only for a live take (or its countdown) on a notched display.
    static func shouldDockToNotch(
        chrome: RecordingControlChrome,
        screenHasNotch: Bool,
        isLiveSession: Bool
    ) -> Bool {
        chrome == .notch && screenHasNotch && isLiveSession
    }

    /// Whether the notched display is the one the take is about (docs/18 REC-9).
    ///
    /// Docking to the built-in display while an external one is recorded puts the controls
    /// on a screen the user is not looking at. A display or region take docks only on its
    /// own display; a window take, which can move, follows the pointer.
    static func notchIsRelevant(
        notchDisplay: CGDirectDisplayID?,
        recordedDisplay: CGDirectDisplayID?,
        pointerDisplay: CGDirectDisplayID?
    ) -> Bool {
        guard let notchDisplay else { return false }
        if let recordedDisplay {
            return recordedDisplay == notchDisplay
        }
        return pointerDisplay == notchDisplay
    }
}
