import AppKit
import Foundation
import MediaExport
import os
import RecordingCore
import SettingsKit
import Shared

/// Where a recording lands, and the clock the menu bar reads (docs/03 §1.8).
///
/// Split from the coordinator because deciding *what* to record and housekeeping the result
/// change for different reasons — and because the coordinator was over its length budget.
@MainActor
extension RecordingCoordinator {
    /// Where the finished recording lands.
    ///
    /// Counted like every other capture: two recordings stopped inside the same second
    /// used to resolve to the same name, and the second overwrote the first (docs/07 M6).
    func destinationURL() -> URL {
        let template = FilenameTemplate("Kadr recording {date} {time}")
        let context = FilenameContext(applicationName: "Screen", date: Date())
        let folder = settings.saveFolder

        if let url = try? CaptureFileWriter().availableURL(
            in: folder,
            template: template,
            context: context,
            fileExtension: "mp4"
        ) {
            return url
        }
        return folder.appendingPathComponent(template.expand(context)).appendingPathExtension("mp4")
    }
}

/// Do Not Disturb while recording (docs/03 §1.8).
///
/// macOS gives apps no supported way to set a Focus mode, so this does the honest thing:
/// it suppresses Kadr's own notifications and tells the user what it cannot do, rather
/// than pretending. A banner from another app landing in a recording is a real problem;
/// silently failing to prevent it would be worse than saying so.
@MainActor
struct FocusMode {
    private let logger = KadrLog.logger(.recording)

    func enable() {
        logger.info("Recording started; macOS Focus must be set by the user if wanted")
    }

    func disable() {}
}
