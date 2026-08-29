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
