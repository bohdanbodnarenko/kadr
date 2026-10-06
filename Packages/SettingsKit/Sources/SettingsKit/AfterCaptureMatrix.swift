import Foundation
import Shared

/// What Kadr does the moment a capture lands (docs/09 U2.2).
///
/// A set rather than a choice. The old single "default action" forced a decision that is
/// not really one — copying and saving are not alternatives, and someone who wants both
/// plus a card had to pick the one enum case that happened to mean all three. Adding
/// "annotate" to that scheme would have meant eight cases and then sixteen.
///
/// Options that compose compose. Options that do not — you cannot both copy and open the
/// editor without the copy being pointless — are still expressible, because refusing them
/// would be second-guessing someone whose workflow we do not know.
public struct AfterCaptureActions: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Put a card on screen.
    public static let overlay = AfterCaptureActions(rawValue: 1 << 0)
    /// Put the capture on the clipboard.
    public static let copy = AfterCaptureActions(rawValue: 1 << 1)
    /// Write it to the save folder immediately, rather than staging it.
    public static let save = AfterCaptureActions(rawValue: 1 << 2)
    /// Open it in the annotation editor.
    public static let annotate = AfterCaptureActions(rawValue: 1 << 3)
    /// Pin it to the screen.
    public static let pin = AfterCaptureActions(rawValue: 1 << 4)
    /// Open a recording in the studio, where its cuts, zooms and camera are edited
    /// (docs/09 U3). A recording with no studio session opens for trimming instead.
    public static let openEditor = AfterCaptureActions(rawValue: 1 << 5)
    /// Prompt for a folder and name instead of writing silently (CleanShot §6.2 / §7).
    public static let promptSave = AfterCaptureActions(rawValue: 1 << 6)

    public static let none: AfterCaptureActions = []

    /// Every action, in the order the settings pane lists them.
    public static let allCases: [AfterCaptureActions] = [
        .overlay, .copy, .save, .promptSave, .annotate, .pin, .openEditor
    ]

    public var title: String {
        switch self {
        case .overlay: String(localized: "Show a card", bundle: .module)
        case .copy: String(localized: "Copy to the clipboard", bundle: .module)
        case .save: String(localized: "Save to the folder", bundle: .module)
        case .promptSave: String(localized: "Ask where to save", bundle: .module)
        case .annotate: String(localized: "Open for annotation", bundle: .module)
        case .pin: String(localized: "Pin to the screen", bundle: .module)
        case .openEditor: String(localized: "Open in the studio", bundle: .module)
        default: String(localized: "Several actions", bundle: .module)
        }
    }

    /// Whether this action makes sense for a given kind of capture.
    ///
    /// Annotating and pinning a movie mean nothing, and offering them would be offering a
    /// button that does nothing — the failure the review found on the cards themselves
    /// (docs/07 M8).
    public func applies(to kind: CaptureKind) -> Bool {
        switch kind {
        case .screenshot: self != .openEditor
        case .recording: self != .annotate && self != .pin && self != .save
        }
    }
}

/// The two kinds of capture the matrix distinguishes (docs/09 U2.2).
///
/// Two rather than one because the useful answers genuinely differ: a screenshot usually
/// wants copying, and copying a two-minute recording to the clipboard is not something
/// anybody wants by default.
public enum CaptureKind: String, CaseIterable, Sendable, Codable {
    case screenshot
    case recording

    public var title: String {
        switch self {
        case .screenshot: String(localized: "Screenshots", bundle: .module)
        case .recording: String(localized: "Recordings", bundle: .module)
        }
    }
}

/// What happens after each kind of capture (docs/09 U2.2).
public struct AfterCaptureMatrix: Hashable, Sendable, Codable {
    public var screenshot: AfterCaptureActions
    public var recording: AfterCaptureActions

    public init(
        screenshot: AfterCaptureActions = [.overlay, .copy],
        recording: AfterCaptureActions = [.overlay]
    ) {
        self.screenshot = screenshot
        self.recording = recording
    }

    public subscript(kind: CaptureKind) -> AfterCaptureActions {
        get {
            switch kind {
            case .screenshot: screenshot
            case .recording: recording
            }
        }
        set {
            // Filtered on the way in, so a row can never hold an action that does nothing
            // for its kind — a stored contradiction outlives whatever set it.
            let filtered = AfterCaptureActions(rawValue: newValue.rawValue)
                .intersection(Self.applicable(to: kind))
            switch kind {
            case .screenshot: screenshot = filtered
            case .recording: recording = filtered
            }
        }
    }

    /// The actions that mean something for a kind of capture.
    public static func applicable(to kind: CaptureKind) -> AfterCaptureActions {
        AfterCaptureActions.allCases
            .filter { $0.applies(to: kind) }
            .reduce(into: AfterCaptureActions.none) { $0.insert($1) }
    }

    /// A card and the clipboard for a screenshot. Recordings always write a file, so the
    /// row no longer offers Save (docs/16 OUT-1).
    public static let standard = AfterCaptureMatrix()

    /// The matrix a pre-U2.2 `DefaultCaptureAction` becomes (docs/09 U2.2).
    ///
    /// A migration rather than a reset, because the old setting is the only statement the
    /// user has ever made about this and throwing it away to show them a new pane would be
    /// rude. Every old case has an exact equivalent; the overlay is added throughout
    /// because the old behaviour always showed a card.
    /// The single old-style action this matrix is exactly equivalent to, or nil when the
    /// user has tuned the matrix past what one radio choice can say. Read by onboarding so
    /// it shows the real behaviour instead of the retired setting (docs/18 SH-6).
    public var equivalentDefaultAction: DefaultCaptureAction? {
        DefaultCaptureAction.allCases.first { Self.migrating($0) == self }
    }

    public static func migrating(_ action: DefaultCaptureAction) -> AfterCaptureMatrix {
        let screenshot: AfterCaptureActions = switch action {
        case .copyToClipboard: [.overlay, .copy]
        case .saveToFolder: [.overlay, .save]
        case .copyAndSave: [.overlay, .copy, .save]
        case .overlayOnly: [.overlay]
        }
        // Recordings were never copied, whatever the setting said: the old output path
        // only ever put a still on the clipboard.
        let recording: AfterCaptureActions = [.overlay]
        return AfterCaptureMatrix(screenshot: screenshot, recording: recording)
    }
}

/// Stored as two integers rather than as JSON.
///
/// `defaults read com.bohdanbodnarenko.kadr` should stay legible, and a raw option-set bitmask is
/// already about as opaque as a preference gets — wrapping it in an encoded blob as well
/// would make it unreadable and un-editable from the command line.
extension AfterCaptureMatrix: SettingValue {
    private static func key(_ base: String, _ kind: CaptureKind) -> String {
        "\(base).\(kind.rawValue)"
    }

    public static func read(from defaults: UserDefaults, forKey key: String) -> AfterCaptureMatrix? {
        guard let screenshot = defaults.object(forKey: Self.key(key, .screenshot)) as? Int,
              let recording = defaults.object(forKey: Self.key(key, .recording)) as? Int
        else {
            return nil
        }
        var matrix = AfterCaptureMatrix()
        matrix[.screenshot] = AfterCaptureActions(rawValue: screenshot)
        matrix[.recording] = AfterCaptureActions(rawValue: recording)
        return matrix
    }

    public func write(to defaults: UserDefaults, forKey key: String) {
        defaults.set(screenshot.rawValue, forKey: Self.key(key, .screenshot))
        defaults.set(recording.rawValue, forKey: Self.key(key, .recording))
    }
}
