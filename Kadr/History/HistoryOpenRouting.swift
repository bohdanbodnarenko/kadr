import Foundation
import HistoryKit
import StudioSession

/// Where History should send a double-tap (docs/03 §5, docs/09 U3).
///
/// Screendrop's Projects browser opens a recording in the studio. Kadr's History used to
/// always show the overlay card, so the only way back into an edit was the card that had
/// already been dismissed.
enum HistoryOpenRouting: Equatable {
    case studio(URL)
    case overlay

    static func destination(
        kind: HistoryItemKind,
        fileURL: URL,
        store: RecordingSessionStore
    ) -> HistoryOpenRouting {
        guard kind == .video, let session = store.session(forFootageAt: fileURL) else {
            return .overlay
        }
        return .studio(session.directory)
    }
}
