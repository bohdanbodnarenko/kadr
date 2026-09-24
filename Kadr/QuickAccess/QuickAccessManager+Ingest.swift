import Foundation
import HistoryKit
import os
import Shared

extension QuickAccessManager {
    /// Shows status for work on a card: over the stack when it is up, otherwise through
    /// `FailurePresenter` (docs/17 T-OUT-2).
    ///
    /// With no card on screen — the last one was just deleted, or the stack is tucked
    /// into the peek tab — a banner in the stack would be invisible, and a failure nobody
    /// sees is the silent failure this exists to prevent.
    func presentFeedback(_ status: FeedbackStatus) {
        guard overlayPanel != nil, !items.isEmpty, !isPeeking, !isExiting else {
            feedbackStatus = nil
            if status.kind != .progress {
                FailurePresenter.present(status)
            }
            return
        }
        feedbackStatus = status
        if status.kind == .completion || status.kind == .warning || status.kind == .error {
            FeedbackAnnouncement.post(status.message)
        }
    }

    func dismissFeedback() {
        feedbackStatus = nil
    }

    /// Recordings need a still ImageIO can thumbnail; the poster is that still.
    func ingestRecording(_ item: QuickAccessItem) {
        Task { [weak self] in
            guard let self else { return }
            let poster = await writePoster(for: item.fileURL)
            ingest(item, thumbnailSourceURL: poster)
        }
    }

    func writePoster(for video: URL) async -> URL? {
        guard let image = await VideoPosterFrame.posterFrame(
            of: video,
            maxPixelSize: HistoryThumbnailWriter.maxPixelSize
        ) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-poster-\(UUID().uuidString).jpg")
        do {
            try HistoryThumbnailWriter.write(image, to: url)
            return url
        } catch {
            logger.error("Could not write a recording poster: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
