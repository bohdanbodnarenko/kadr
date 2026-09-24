import Foundation

/// A studio failure with severity, message, and the next useful action (docs/14 UX-35).
///
/// A single `String` could only ever end in one modal titled "The studio could not do
/// that", which hid whether the remedy was Settings, retry, or picking another file.
public struct StudioFailurePresentation: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var title: String
    public var message: String
    public var style: Style
    public var primaryAction: Action
    public var secondaryAction: Action?

    public enum Style: Equatable, Sendable {
        /// Recoverable workflow errors stay in the chrome.
        case inlineBanner
        /// Decisions or destructive consequences use a sheet.
        case sheet
    }

    public enum Action: Equatable, Sendable {
        case dismiss
        case retry
        case openSpeechSettings
        case chooseExportLocation
    }

    public init(
        title: String,
        message: String,
        style: Style = .inlineBanner,
        primaryAction: Action = .dismiss,
        secondaryAction: Action? = nil
    ) {
        self.title = title
        self.message = message
        self.style = style
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
    }

    // MARK: - Common failures

    public static func exportFailed(_ detail: String) -> Self {
        Self(
            title: "Kadr could not export this recording.",
            message: detail,
            primaryAction: .retry,
            secondaryAction: .chooseExportLocation
        )
    }

    public static func importFailed(_ detail: String) -> Self {
        Self(
            title: "Kadr could not import that file.",
            message: detail
        )
    }

    public static func noAudioTrack() -> Self {
        Self(
            title: "This recording has no audio.",
            message: "Choose a file with a soundtrack, or record again with audio enabled."
        )
    }

    public static func audioExportFailed(_ detail: String) -> Self {
        Self(
            title: "Kadr could not export the soundtrack.",
            message: detail,
            primaryAction: .retry
        )
    }

    public static func speechPermissionNeeded() -> Self {
        Self(
            title: "Speech recognition is turned off.",
            message: "Kadr needs permission to use speech recognition. Grant it in "
                + "System Settings ▸ Privacy & Security ▸ Speech Recognition.",
            primaryAction: .openSpeechSettings
        )
    }

    public static func speechModelDownloadFailed(_ detail: String) -> Self {
        Self(
            title: "The language model could not download.",
            message: detail,
            primaryAction: .retry
        )
    }

    public static func speechModelStorageFull() -> Self {
        Self(
            title: "Not enough free space.",
            message: "There is not enough free space on this Mac to download the language model."
        )
    }

    public static func transcriptionFailed(_ detail: String) -> Self {
        Self(
            title: "Kadr could not transcribe this recording.",
            message: detail,
            primaryAction: .retry
        )
    }

    public static func tidyRefused() -> Self {
        Self(
            title: "Speech tidying is unavailable after clip edits.",
            message: "Speech tidying works on a recording you have not cut or re-timed yet. "
                + "Undo your clip edits first, or trim the pauses by hand.",
            style: .sheet
        )
    }

    public static func onlyClipLeft() -> Self {
        Self(
            title: "This is the only clip.",
            message: "Delete the recording itself if that is what you meant."
        )
    }

    public static func noClickClusters() -> Self {
        Self(
            title: "No click clusters found.",
            message: "There were no click clusters to zoom to in this recording."
        )
    }

    public static func copyEditedFailed(_ detail: String) -> Self {
        Self(
            title: "Kadr could not copy this edit.",
            message: detail,
            primaryAction: .retry
        )
    }

    public static func shareEditedFailed(_ detail: String) -> Self {
        Self(
            title: "Kadr could not share this edit.",
            message: detail,
            primaryAction: .retry
        )
    }

    /// docs/17 T-STU-9: an edit this build could not read was kept, not overwritten.
    public static func unreadableEditBackedUp(_ fileName: String) -> Self {
        Self(
            title: "This recording's edit couldn't be read.",
            message: "It may have been saved by a newer version of Kadr. It was kept in the recording "
                + "as “\(fileName)”, and the recording opened without it."
        )
    }
}
