import AppKit
import SettingsKit

/// Remembered placement for the recording bar and the camera bubble, across launches
/// (docs/18 REC P3).
///
/// Both panels are built deep inside objects that never see the settings, and their
/// placement used to be static variables forgotten on relaunch. This keeps the static
/// shape their callers already use and backs it with `AppSettings`, which the app sets once
/// at launch. Without settings (tests, previews) placement lasts for the process only.
@MainActor
enum RecordingPlacement {
    static var settings: AppSettings?
    private static var fallback: [String: String] = [:]

    static var barOrigin: CGPoint? {
        get { point(settings?.recordingBarOrigin ?? fallback["bar"]) }
        set {
            let text = newValue.map { NSStringFromPoint($0) } ?? ""
            if let settings { settings.recordingBarOrigin = text } else { fallback["bar"] = text }
        }
    }

    static var cameraOrigin: CGPoint? {
        get { point(settings?.cameraBubbleOrigin ?? fallback["camera"]) }
        set {
            let text = newValue.map { NSStringFromPoint($0) } ?? ""
            if let settings { settings.cameraBubbleOrigin = text } else { fallback["camera"] = text }
        }
    }

    static var cameraDiameter: CGFloat {
        get { CGFloat(settings?.cameraBubbleDiameter ?? Double(fallback["diameter"] ?? "") ?? 160) }
        set {
            if let settings { settings.cameraBubbleDiameter = Double(newValue) } else {
                fallback["diameter"] = String(Double(newValue))
            }
        }
    }

    static var cameraIsCircular: Bool {
        get { settings?.cameraBubbleIsCircular ?? (fallback["circular"] != "false") }
        set {
            if let settings { settings.cameraBubbleIsCircular = newValue } else {
                fallback["circular"] = newValue ? "true" : "false"
            }
        }
    }

    /// A stored point, or nil for "never placed".
    nonisolated static func point(_ text: String?) -> CGPoint? {
        // `NSPointFromString` reads anything unparseable as the origin, which would put a
        // never-placed panel in the corner; only its own `{x, y}` form counts.
        guard let text, text.hasPrefix("{") else { return nil }
        let point = NSPointFromString(text)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }
}
