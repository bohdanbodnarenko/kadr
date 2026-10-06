import Foundation

/// Where the next screenshot goes, as the capture island's Save menu shows it.
///
/// The island's menu used to flip `askForSaveDestination`, which only changes what a
/// card's Save button does, so "Ask where to save" there never asked about the capture
/// being taken (docs/17 T-CAP-12). It now reads and writes the screenshot row of the
/// after-capture matrix, which is what decides that (docs/03 §2).
public enum ScreenshotSaveTarget: String, CaseIterable, Sendable {
    /// Saved straight into the capture folder.
    case folder
    /// A save panel as soon as the capture lands.
    case ask
    /// Not saved until the card is acted on.
    case none

    public var title: String {
        switch self {
        case .folder: String(localized: "Save to the folder", bundle: .module)
        case .ask: String(localized: "Ask where to save", bundle: .module)
        case .none: String(localized: "Don't save until I choose", bundle: .module)
        }
    }
}

public extension AfterCaptureMatrix {
    /// The screenshot row's save behaviour. Setting it changes only the two save actions,
    /// so copy, card, pin and annotate stay as the user arranged them.
    var screenshotSaveTarget: ScreenshotSaveTarget {
        get {
            if screenshot.contains(.promptSave) {
                return .ask
            }
            if screenshot.contains(.save) {
                return .folder
            }
            return .none
        }
        set {
            var row = screenshot
            row.remove(.save)
            row.remove(.promptSave)
            switch newValue {
            case .folder: row.insert(.save)
            case .ask: row.insert(.promptSave)
            case .none: break
            }
            // Nothing visible left would make the capture vanish; the card keeps it reachable.
            if newValue == .none, row.isDisjoint(with: [.copy, .annotate, .pin]) {
                row.insert(.overlay)
            }
            self[.screenshot] = row
        }
    }
}
